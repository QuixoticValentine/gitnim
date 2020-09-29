#
#
#           The Nim Compiler
#        (c) Copyright 2020 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Partition variables into different graphs. Used for
## Nim's write tracking and also for the cursor inference.
## The algorithm is a reinvention / variation of Steensgaard's
## algorithm.
## The used data structure is "union find" with path compression.

## We perform two passes over the AST:
## - Pass one (``computeLiveRanges``): collect livetimes of local
##   variables and whether they are potentially re-assigned.
## - Pass two (``traverse``): combine local variables to abstract "graphs".
##   Strict func checking: Ensure that graphs that are connected to
##   const parameters are not mutated.
##   Cursor inference: Ensure that potential cursors are not
##     borrowed from locations that are connected to a graph
##     that is mutated during the liveness of the cursor.
##     (We track all possible mutations of a graph.)

import ast, types, lineinfos, options, msgs, renderer
from trees import getMagic, whichPragma
from wordrecg import wNoSideEffect
from isolation_check import canAlias
from typeallowed import isViewType

type
  SubgraphFlag = enum
    isMutated, # graph might be mutated
    connectsConstParam, # graph is connected to a non-var parameter.

  VarFlag = enum
    ownsData,
    preventCursor,
    isReassigned

  VarIndexKind = enum
    isEmptyRoot,
    dependsOn,
    isRootOf

  Connection = object
    case kind: VarIndexKind
    of isEmptyRoot: discard
    of dependsOn: parent: int
    of isRootOf: graphIndex: int

  VarIndex = object
    con: Connection
    flags: set[VarFlag]
    sym: PSym
    reassignedTo: int
    aliveStart, aliveEnd: int # the range for which the variable is alive.

  MutationInfo* = object
    param: PSym
    mutatedHere, connectedVia: TLineInfo
    flags: set[SubgraphFlag]
    maxMutation, minConnection: int
    mutations: seq[int]

  Partitions* = object
    abstractTime: int
    s: seq[VarIndex]
    graphs: seq[MutationInfo]
    unanalysableMutation, performCursorInference: bool
    inAsgnSource, inConstructor, inNoSideEffectSection: int

proc mutationAfterConnection(g: MutationInfo): bool {.inline.} =
  #echo g.maxMutation, " ", g.minConnection, " ", g.param
  g.maxMutation > g.minConnection

proc `$`*(config: ConfigRef; g: MutationInfo): string =
  result = ""
  if g.flags == {isMutated, connectsConstParam}:
    result.add "\nan object reachable from '"
    result.add g.param.name.s
    result.add "' is potentially mutated"
    if g.mutatedHere != unknownLineInfo:
      result.add "\n"
      result.add config $ g.mutatedHere
      result.add " the mutation is here"
    if g.connectedVia != unknownLineInfo:
      result.add "\n"
      result.add config $ g.connectedVia
      result.add " is the statement that connected the mutation to the parameter"

proc hasSideEffect*(c: var Partitions; info: var MutationInfo): bool =
  for g in mitems c.graphs:
    if g.flags == {isMutated, connectsConstParam} and mutationAfterConnection(g):
      info = g
      return true
  return false

template isConstParam(a): bool = a.kind == skParam and a.typ.kind != tyVar

proc variableId(c: Partitions; x: PSym): int =
  for i in 0 ..< c.s.len:
    if c.s[i].sym == x: return i
  return -1

proc registerResult(c: var Partitions; n: PNode) =
  if n.kind == nkSym:
    c.s.add VarIndex(con: Connection(kind: isEmptyRoot), sym: n.sym, reassignedTo: 0,
                      aliveStart: high(int), aliveEnd: c.abstractTime)

proc registerParam(c: var Partitions; n: PNode) =
  assert n.kind == nkSym
  if isConstParam(n.sym):
    c.s.add VarIndex(con: Connection(kind: isRootOf, graphIndex: c.graphs.len),
                      sym: n.sym, reassignedTo: 0,
                      aliveStart: c.abstractTime, aliveEnd: c.abstractTime)
    c.graphs.add MutationInfo(param: n.sym, mutatedHere: unknownLineInfo,
                          connectedVia: unknownLineInfo, flags: {connectsConstParam},
                          maxMutation: -1, minConnection: high(int),
                          mutations: @[])
  else:
    c.s.add VarIndex(con: Connection(kind: isEmptyRoot), sym: n.sym, reassignedTo: 0,
                     aliveStart: c.abstractTime, aliveEnd: c.abstractTime)

proc registerVariable(c: var Partitions; n: PNode) =
  if n.kind == nkSym and variableId(c, n.sym) < 0:
    c.s.add VarIndex(con: Connection(kind: isEmptyRoot), sym: n.sym, reassignedTo: 0,
                     aliveStart: c.abstractTime, aliveEnd: c.abstractTime)

proc root(v: var Partitions; start: int): int =
  result = start
  var depth = 0
  while v.s[result].con.kind == dependsOn:
    result = v.s[result].con.parent
    inc depth
  if depth > 0:
    # path compression:
    var it = start
    while v.s[it].con.kind == dependsOn:
      let next = v.s[it].con.parent
      v.s[it].con = Connection(kind: dependsOn, parent: result)
      it = next

proc potentialMutation(v: var Partitions; s: PSym; info: TLineInfo) =
  let id = variableId(v, s)
  if id >= 0:
    let r = root(v, id)
    case v.s[r].con.kind
    of isEmptyRoot:
      v.s[r].con = Connection(kind: isRootOf, graphIndex: v.graphs.len)
      v.graphs.add MutationInfo(param: if isConstParam(s): s else: nil, mutatedHere: info,
                            connectedVia: unknownLineInfo, flags: {isMutated},
                            maxMutation: v.abstractTime, minConnection: high(int),
                            mutations: @[v.abstractTime])
    of isRootOf:
      let g = addr v.graphs[v.s[r].con.graphIndex]
      if g.param == nil and isConstParam(s):
        g.param = s
      if v.abstractTime > g.maxMutation:
        g.mutatedHere = info
        g.maxMutation = v.abstractTime
      g.flags.incl isMutated
      g.mutations.add v.abstractTime
    else:
      assert false, "cannot happen"
  else:
    v.unanalysableMutation = true

proc connect(v: var Partitions; a, b: PSym; info: TLineInfo) =
  let aid = variableId(v, a)
  if aid < 0:
    return
  let bid = variableId(v, b)
  if bid < 0:
    return

  let ra = root(v, aid)
  let rb = root(v, bid)
  if ra != rb:
    var param = PSym(nil)
    if isConstParam(a): param = a
    elif isConstParam(b): param = b

    let paramFlags =
      if param != nil:
        {connectsConstParam}
      else:
        {}

    # for now we always make 'rb' the slave and 'ra' the master:
    var rbFlags: set[SubgraphFlag] = {}
    var mutatedHere = unknownLineInfo
    var mut = 0
    var con = v.abstractTime
    var gb: ptr MutationInfo = nil
    if v.s[rb].con.kind == isRootOf:
      gb = addr v.graphs[v.s[rb].con.graphIndex]
      if param == nil: param = gb.param
      mutatedHere = gb.mutatedHere
      rbFlags = gb.flags
      mut = gb.maxMutation
      con = min(con, gb.minConnection)

    v.s[rb].con = Connection(kind: dependsOn, parent: ra)
    case v.s[ra].con.kind
    of isEmptyRoot:
      v.s[ra].con = Connection(kind: isRootOf, graphIndex: v.graphs.len)
      v.graphs.add MutationInfo(param: param, mutatedHere: mutatedHere,
                            connectedVia: info, flags: paramFlags + rbFlags,
                            maxMutation: mut, minConnection: con,
                            mutations: if gb != nil: gb.mutations else: @[])
    of isRootOf:
      var g = addr v.graphs[v.s[ra].con.graphIndex]
      if g.param == nil: g.param = param
      if g.mutatedHere == unknownLineInfo: g.mutatedHere = mutatedHere
      g.minConnection = min(g.minConnection, con)
      g.connectedVia = info
      g.flags.incl paramFlags + rbFlags
      if gb != nil:
        g.mutations.add gb.mutations
    else:
      assert false, "cannot happen"

proc allRoots(n: PNode; result: var seq[PSym]; followDotExpr = true) =
  case n.kind
  of nkSym:
    if n.sym.kind in {skParam, skVar, skTemp, skLet, skResult, skForVar}:
      result.add(n.sym)

  of nkDotExpr, nkDerefExpr, nkBracketExpr, nkHiddenDeref,
      nkCheckedFieldExpr, nkAddr, nkHiddenAddr:
    if followDotExpr:
      allRoots(n[0], result, followDotExpr)

  of nkExprEqExpr, nkExprColonExpr, nkHiddenStdConv, nkHiddenSubConv, nkConv,
      nkStmtList, nkStmtListExpr, nkBlockStmt, nkBlockExpr, nkCast,
      nkObjUpConv, nkObjDownConv:
    if n.len > 0:
      allRoots(n.lastSon, result, followDotExpr)
  of nkCaseStmt, nkObjConstr:
    for i in 1..<n.len:
      allRoots(n[i].lastSon, result, followDotExpr)
  of nkIfStmt, nkIfExpr:
    for i in 0..<n.len:
      allRoots(n[i].lastSon, result, followDotExpr)
  of nkBracket, nkTupleConstr, nkPar:
    for i in 0..<n.len:
      allRoots(n[i], result, followDotExpr)

  of nkCallKinds:
    if n.typ != nil and n.typ.kind in {tyVar, tyLent}:
      if n.len > 1:
        allRoots(n[1], result, followDotExpr)
    else:
      let m = getMagic(n)
      case m
      of mNone:
        if n[0].typ.isNil: return
        var typ = n[0].typ
        if typ != nil:
          typ = skipTypes(typ, abstractInst)
          if typ.kind != tyProc: typ = nil
          else: assert(typ.len == typ.n.len)

        for i in 1 ..< n.len:
          let it = n[i]
          if typ != nil and i < typ.len:
            assert(typ.n[i].kind == nkSym)
            let paramType = typ.n[i].typ
            if not paramType.isCompileTimeOnly and not typ.sons[0].isEmptyType and
                canAlias(paramType, typ.sons[0]):
              allRoots(it, result, followDotExpr)
          else:
            allRoots(it, result, followDotExpr)

      of mSlice:
        allRoots(n[1], result, followDotExpr)
      else:
        discard "harmless operation"
  else:
    discard "nothing to do"

proc destMightOwn(c: var Partitions; dest: var VarIndex; n: PNode) =
  ## Analyse if 'n' is an expression that owns the data, if so mark 'dest'
  ## with 'ownsData'.
  case n.kind
  of nkEmpty, nkCharLit..nkNilLit:
    # primitive literals including the empty are harmless:
    discard

  of nkExprEqExpr, nkExprColonExpr, nkHiddenStdConv, nkHiddenSubConv, nkCast, nkConv:
    destMightOwn(c, dest, n[1])

  of nkIfStmt, nkIfExpr:
    for i in 0..<n.len:
      destMightOwn(c, dest, n[i].lastSon)

  of nkCaseStmt:
    for i in 1..<n.len:
      destMightOwn(c, dest, n[i].lastSon)

  of nkStmtList, nkStmtListExpr:
    if n.len > 0:
      destMightOwn(c, dest, n[^1])

  of nkClosure:
    for i in 1..<n.len:
      destMightOwn(c, dest, n[i])
    # you must destroy a closure:
    dest.flags.incl ownsData

  of nkObjConstr:
    for i in 1..<n.len:
      destMightOwn(c, dest, n[i])
    if hasDestructor(n.typ):
      # you must destroy a ref object:
      dest.flags.incl ownsData

  of nkCurly, nkBracket, nkPar, nkTupleConstr:
    inc c.inConstructor
    for son in n:
      destMightOwn(c, dest, son)
    dec c.inConstructor
    if n.typ.skipTypes(abstractInst).kind == tySequence:
      # you must destroy a sequence:
      dest.flags.incl ownsData

  of nkSym:
    if n.sym.kind in {skVar, skResult, skTemp, skLet, skForVar, skParam}:
      if n.sym.flags * {sfThread, sfGlobal} != {}:
        # aliasing a global is inherently dangerous:
        dest.flags.incl ownsData
      else:
        # otherwise it's just a dependency, nothing to worry about:
        connect(c, dest.sym, n.sym, n.info)
        # but a construct like ``[symbol]`` is dangerous:
        if c.inConstructor > 0: dest.flags.incl ownsData

  of nkDotExpr, nkBracketExpr, nkHiddenDeref, nkDerefExpr,
      nkObjUpConv, nkObjDownConv, nkCheckedFieldExpr, nkAddr, nkHiddenAddr:
    destMightOwn(c, dest, n[0])

  of nkCallKinds:
    if hasDestructor(n.typ):
      # calls do construct, what we construct must be destroyed,
      # so dest cannot be a cursor:
      dest.flags.incl ownsData
    elif n.typ.kind in {tyLent, tyVar}:
      # we know the result is derived from the first argument:
      var roots: seq[PSym]
      allRoots(n[1], roots)
      for r in roots:
        connect(c, dest.sym, r, n[1].info)

    else:
      let magic = if n[0].kind == nkSym: n[0].sym.magic else: mNone
      # this list is subtle, we try to answer the question if after 'dest = f(src)'
      # there is a connection betwen 'src' and 'dest' so that mutations to 'src'
      # also reflect 'dest':
      if magic in {mNone, mMove, mSlice, mAppendStrCh, mAppendStrStr, mAppendSeqElem, mArrToSeq}:
        for i in 1..<n.len:
          # we always have to assume a 'select(...)' like mechanism.
          # But at least we do filter out simple POD types from the
          # list of dependencies via the 'hasDestructor' check for
          # the root's symbol.
          if hasDestructor(n[i].typ.skipTypes({tyVar, tySink, tyLent, tyGenericInst, tyAlias})):
            destMightOwn(c, dest, n[i])

  else:
    # something we cannot handle:
    dest.flags.incl preventCursor

proc noCursor(c: var Partitions, s: PSym) =
  let vid = variableId(c, s)
  if vid >= 0:
    c.s[vid].flags.incl preventCursor

proc pretendOwnsData(c: var Partitions, s: PSym) =
  let vid = variableId(c, s)
  if vid >= 0:
    c.s[vid].flags.incl ownsData

const
  explainCursors = false

proc deps(c: var Partitions; dest, src: PNode) =
  var targets, sources: seq[PSym]
  allRoots(dest, targets)
  allRoots(src, sources)

  proc wrap(t: PType): bool {.nimcall.} = t.kind in {tyRef, tyPtr}
  let destIsComplex = types.searchTypeFor(dest.typ, wrap) or isViewType(dest.typ)

  for t in targets:
    if dest.kind != nkSym and c.inNoSideEffectSection == 0:
      potentialMutation(c, t, dest.info)

    if destIsComplex:
      for s in sources:
        connect(c, t, s, dest.info)

  if c.performCursorInference and src.kind != nkEmpty:
    if dest.kind == nkSym:
      let vid = variableId(c, dest.sym)
      if vid >= 0:
        destMightOwn(c, c.s[vid], src)
        for s in sources:
          if s == dest.sym:
            discard "assignments like: it = it.next are fine"
          elif {sfGlobal, sfThread} * s.flags != {} or hasDisabledAsgn(s.typ):
            # do not borrow from a global variable or from something with a
            # disabled assignment operator.
            c.s[vid].flags.incl preventCursor
            when explainCursors: echo "A not a cursor: ", dest.sym, " ", s
          else:
            let srcid = variableId(c, s)
            if srcid >= 0:
              if s.kind notin {skResult, skParam} and (
                  c.s[srcid].aliveEnd < c.s[vid].aliveEnd):
                # you cannot borrow from a local that lives shorter than 'vid':
                when explainCursors: echo "B not a cursor ", dest.sym, " ", c.s[srcid].aliveEnd, " ", c.s[vid].aliveEnd
                c.s[vid].flags.incl preventCursor
              elif {isReassigned, preventCursor} * c.s[srcid].flags != {}:
                # you cannot borrow from something that is re-assigned:
                when explainCursors: echo "C not a cursor ", dest.sym, " ", c.s[srcid].flags, " reassignedTo ", c.s[srcid].reassignedTo
                c.s[vid].flags.incl preventCursor
              elif c.s[srcid].reassignedTo != 0 and c.s[srcid].reassignedTo != dest.sym.id:
                when explainCursors: echo "D not a cursor ", dest.sym, " reassignedTo ", c.s[srcid].reassignedTo
                c.s[vid].flags.incl preventCursor

const
  nodesToIgnoreSet = {nkNone..pred(nkSym), succ(nkSym)..nkNilLit,
    nkTypeSection, nkProcDef, nkConverterDef,
    nkMethodDef, nkIteratorDef, nkMacroDef, nkTemplateDef, nkLambda, nkDo,
    nkFuncDef, nkConstSection, nkConstDef, nkIncludeStmt, nkImportStmt,
    nkExportStmt, nkPragma, nkCommentStmt, nkBreakState, nkTypeOfExpr}

proc traverse(c: var Partitions; n: PNode) =
  inc c.abstractTime
  case n.kind
  of nkLetSection, nkVarSection:
    for child in n:
      let last = lastSon(child)
      traverse(c, last)
      if child.kind == nkVarTuple and last.kind in {nkPar, nkTupleConstr}:
        if child.len-2 != last.len: return
        for i in 0..<child.len-2:
          #registerVariable(c, child[i])
          deps(c, child[i], last[i])
      else:
        for i in 0..<child.len-2:
          #registerVariable(c, child[i])
          deps(c, child[i], last)
  of nkAsgn, nkFastAsgn:
    traverse(c, n[0])
    inc c.inAsgnSource
    traverse(c, n[1])
    dec c.inAsgnSource
    deps(c, n[0], n[1])
  of nkSym:
    dec c.abstractTime

  of nodesToIgnoreSet:
    dec c.abstractTime
    discard "do not follow the construct"
  of nkCallKinds:
    for child in n: traverse(c, child)

    let parameters = n[0].typ
    let L = if parameters != nil: parameters.len else: 0

    for i in 1..<n.len:
      let it = n[i]
      if i < L:
        let paramType = parameters[i].skipTypes({tyGenericInst, tyAlias})
        if not paramType.isCompileTimeOnly and paramType.kind in {tyVar, tySink, tyOwned}:
          var roots: seq[PSym]
          allRoots(it, roots)
          if paramType.kind == tyVar:
            if c.inNoSideEffectSection == 0:
              for r in roots: potentialMutation(c, r, it.info)
            for r in roots: noCursor(c, r)

  of nkAddr, nkHiddenAddr:
    traverse(c, n[0])
    when false:
      # XXX investigate if this is required, it doesn't look
      # like it is!
      var roots: seq[PSym]
      allRoots(n[0], roots)
      for r in roots:
        potentialMutation(c, r, it.info)

  of nkTupleConstr, nkBracket:
    for child in n: traverse(c, child)
    if c.inAsgnSource > 0:
      for i in 0..<n.len:
        if n[i].kind == nkSym:
          # we assume constructions with cursors are better without
          # the cursors because it's likely we can move then, see
          # test arc/topt_no_cursor.nim
          pretendOwnsData(c, n[i].sym)

  of nkObjConstr:
    for child in n: traverse(c, child)
    if c.inAsgnSource > 0:
      for i in 1..<n.len:
        let it = n[i].skipColon
        if it.kind == nkSym:
          # we assume constructions with cursors are better without
          # the cursors because it's likely we can move then, see
          # test arc/topt_no_cursor.nim
          pretendOwnsData(c, it.sym)

  of nkPragmaBlock:
    let pragmaList = n[0]
    var enforceNoSideEffects = 0
    for i in 0..<pragmaList.len:
      if whichPragma(pragmaList[i]) == wNoSideEffect:
        enforceNoSideEffects = 1
        break

    inc c.inNoSideEffectSection, enforceNoSideEffects
    traverse(c, n.lastSon)
    dec c.inNoSideEffectSection, enforceNoSideEffects
  of nkWhileStmt, nkForStmt, nkParForStmt:
    for child in n: traverse(c, child)
    # analyse loops twice so that 'abstractTime' suffices to detect cases
    # like:
    #   while cond:
    #     mutate(graph)
    #     connect(graph, cursorVar)
    for child in n: traverse(c, child)
  else:
    for child in n: traverse(c, child)

proc computeLiveRanges(c: var Partitions; n: PNode) =
  # first pass: Compute live ranges for locals.
  # **Watch out!** We must traverse the tree like 'traverse' does
  # so that the 'c.abstractTime' is consistent.
  inc c.abstractTime
  case n.kind
  of nkLetSection, nkVarSection:
    for child in n:
      let last = lastSon(child)
      computeLiveRanges(c, last)
      if child.kind == nkVarTuple and last.kind in {nkPar, nkTupleConstr}:
        if child.len-2 != last.len: return
        for i in 0..<child.len-2:
          registerVariable(c, child[i])
          #deps(c, child[i], last[i])
      else:
        for i in 0..<child.len-2:
          registerVariable(c, child[i])
          #deps(c, child[i], last)

  of nkAsgn, nkFastAsgn:
    computeLiveRanges(c, n[0])
    computeLiveRanges(c, n[1])
    if n[0].kind == nkSym:
      let vid = variableId(c, n[0].sym)
      if vid >= 0:
        if n[1].kind == nkSym and (c.s[vid].reassignedTo == 0 or c.s[vid].reassignedTo == n[1].sym.id):
          c.s[vid].reassignedTo = n[1].sym.id
        else:
          c.s[vid].flags.incl isReassigned

  of nkSym:
    dec c.abstractTime
    if n.sym.kind in {skVar, skResult, skTemp, skLet, skForVar, skParam}:
      let id = variableId(c, n.sym)
      if id >= 0:
        c.s[id].aliveEnd = max(c.s[id].aliveEnd, c.abstractTime)
        if n.sym.kind == skResult:
          c.s[id].aliveStart = min(c.s[id].aliveStart, c.abstractTime)

  of nodesToIgnoreSet:
    dec c.abstractTime
    discard "do not follow the construct"
  of nkCallKinds:
    for child in n: computeLiveRanges(c, child)

    let parameters = n[0].typ
    let L = if parameters != nil: parameters.len else: 0

    for i in 1..<n.len:
      let it = n[i]
      if it.kind == nkSym and i < L:
        let paramType = parameters[i].skipTypes({tyGenericInst, tyAlias})
        if not paramType.isCompileTimeOnly and paramType.kind == tyVar:
          let vid = variableId(c, it.sym)
          if vid >= 0:
            c.s[vid].flags.incl isReassigned

  of nkAddr, nkHiddenAddr:
    computeLiveRanges(c, n[0])
    if n[0].kind == nkSym:
      let vid = variableId(c, n[0].sym)
      if vid >= 0:
        c.s[vid].flags.incl preventCursor

  of nkPragmaBlock:
    computeLiveRanges(c, n.lastSon)
  of nkWhileStmt, nkForStmt, nkParForStmt:
    for child in n: computeLiveRanges(c, child)
    # analyse loops twice so that 'abstractTime' suffices to detect cases
    # like:
    #   while cond:
    #     mutate(graph)
    #     connect(graph, cursorVar)
    for child in n: computeLiveRanges(c, child)
  else:
    for child in n: computeLiveRanges(c, child)

proc computeGraphPartitions*(s: PSym; n: PNode; cursorInference = false): Partitions =
  result = Partitions(performCursorInference: cursorInference)
  if s.kind notin {skModule, skMacro}:
    let params = s.typ.n
    for i in 1..<params.len:
      registerParam(result, params[i])
    if resultPos < s.ast.safeLen:
      registerResult(result, s.ast[resultPos])

  computeLiveRanges(result, n)
  # resart the timer for the second pass:
  result.abstractTime = 0
  traverse(result, n)

proc dangerousMutation(g: MutationInfo; v: VarIndex): bool =
  #echo "range ", v.aliveStart, " .. ", v.aliveEnd, " ", v.sym
  if isMutated in g.flags:
    for m in g.mutations:
      #echo "mutation ", m
      if m in v.aliveStart..v.aliveEnd:
        return true
  return false

proc cannotBorrow(config: ConfigRef; s: PSym; g: MutationInfo) =
  var m = "cannot borrow " & s.name.s &
    "; what it borrows from is potentially mutated"

  if g.mutatedHere != unknownLineInfo:
    m.add "\n"
    m.add config $ g.mutatedHere
    m.add " the mutation is here"
  if g.connectedVia != unknownLineInfo:
    m.add "\n"
    m.add config $ g.connectedVia
    m.add " is the statement that connected the mutation to the parameter"
  localError(config, s.info, m)

proc checkBorrowedLocations*(par: var Partitions; body: PNode; config: ConfigRef) =
  for i in 0 ..< par.s.len:
    let s = par.s[i].sym
    if s.kind != skParam and isViewType(s.typ):
      let rid = root(par, i)
      if par.s[rid].con.kind == isRootOf and dangerousMutation(par.graphs[par.s[rid].con.graphIndex], par.s[i]):
        cannotBorrow(config, s, par.graphs[par.s[rid].con.graphIndex])

proc computeCursors*(s: PSym; n: PNode; config: ConfigRef) =
  var par = computeGraphPartitions(s, n, true)
  for i in 0 ..< par.s.len:
    let v = addr(par.s[i])
    if v.flags * {ownsData, preventCursor} == {} and v.sym.kind notin {skParam, skResult} and
        v.sym.flags * {sfThread, sfGlobal} == {} and hasDestructor(v.sym.typ) and
        v.sym.typ.skipTypes({tyGenericInst, tyAlias}).kind != tyOwned:
      let rid = root(par, i)
      if par.s[rid].con.kind == isRootOf and dangerousMutation(par.graphs[par.s[rid].con.graphIndex], par.s[i]):
        discard "cannot cursor into a graph that is mutated"
      else:
        v.sym.flags.incl sfCursor
        #echo "this is now a cursor ", v.sym, " ", par.s[rid].flags, " ", config $ v.sym.info
