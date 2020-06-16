##[
This module implements a hookable (de)serialization for arbitrary types.
Design goal: avoid importing modules where a custom serialization is needed;
see strtabs.fromJsonHook,toJsonHook for an example.
]##

runnableExamples:
  import std/[strtabs,json]
  type Foo = ref object
    t: bool
    z1: int8
  let a = (1.5'f32, (b: "b2", a: "a2"), 'x', @[Foo(t: true, z1: -3), nil], [{"name": "John"}.newStringTable])
  let j = a.toJson
  doAssert j.jsonTo(type(a)).toJson == j

import std/[json,tables,strutils]

#[
xxx
use toJsonHook,fromJsonHook for Table|OrderedTable
add Options support also using toJsonHook,fromJsonHook and remove `json=>options` dependency

Future directions:
add a way to customize serialization, for eg:
* allowing missing or extra fields in JsonNode
* field renaming
* allow serializing `enum` and `char` as `string` instead of `int`
  (enum is more compact/efficient, and robust to enum renamings, but string
  is more human readable)
* handle cyclic references, using a cache of already visited addresses
]#

proc isNamedTuple(T: typedesc): bool {.magic: "TypeTrait".}
proc distinctBase(T: typedesc): typedesc {.magic: "TypeTrait".}
template distinctBase[T](a: T): untyped = distinctBase(type(a))(a)

proc checkJsonImpl(cond: bool, condStr: string, msg = "") =
  if not cond:
    # just pick 1 exception type for simplicity; other choices would be:
    # JsonError, JsonParser, JsonKindError
    raise newException(ValueError, msg)

template checkJson(cond: untyped, msg = "") =
  checkJsonImpl(cond, astToStr(cond), msg)

proc fromJson*[T](a: var T, b: JsonNode) =
  ## inplace version of `jsonTo`
  #[
  adding "json path" leading to `b` can be added in future work.
  ]#
  checkJson b != nil, $($T, b)
  when compiles(fromJsonHook(a, b)): fromJsonHook(a, b)
  elif T is bool: a = to(b,T)
  elif T is Table | OrderedTable:
    a.clear
    for k,v in b:
      a[k] = jsonTo(v, typeof(a[k]))
  elif T is enum:
    case b.kind
    of JInt: a = T(b.getBiggestInt())
    of JString: a = parseEnum[T](b.getStr())
    else: checkJson false, $($T, " ", b)
  elif T is Ordinal: a = T(to(b, int))
  elif T is pointer: a = cast[pointer](to(b, int))
  elif T is distinct:
    when nimvm:
      # bug, potentially related to https://github.com/nim-lang/Nim/issues/12282
      a = T(jsonTo(b, distinctBase(T)))
    else:
      a.distinctBase.fromJson(b)
  elif T is string|SomeNumber: a = to(b,T)
  elif T is JsonNode: a = b
  elif T is ref | ptr:
    if b.kind == JNull: a = nil
    else:
      a = T()
      fromJson(a[], b)
  elif T is array:
    checkJson a.len == b.len, $(a.len, b.len, $T)
    var i = 0
    for ai in mitems(a):
      fromJson(ai, b[i])
      i.inc
  elif T is seq:
    a.setLen b.len
    for i, val in b.getElems:
      fromJson(a[i], val)
  elif T is object | tuple:
    const isNamed = T is object or isNamedTuple(T)
    when isNamed:
      checkJson b.kind == JObject, $(b.kind) # we could customize whether to allow JNull
      var num = 0
      for key, val in fieldPairs(a):
        num.inc
        if b.hasKey key:
          fromJson(val, b[key])
        else:
          # we could customize to allow this
          checkJson false, $($T, key, b)
      checkJson b.len == num, $(b.len, num, $T, b) # could customize
    else:
      checkJson b.kind == JArray, $(b.kind) # we could customize whether to allow JNull
      var i = 0
      for val in fields(a):
        fromJson(val, b[i])
        i.inc
  else:
    # checkJson not appropriate here
    static: doAssert false, "not yet implemented: " & $T

proc jsonTo*(b: JsonNode, T: typedesc): T =
  ## reverse of `toJson`
  fromJson(result, b)

proc toJson*[T](a: T): JsonNode =
  ## serializes `a` to json; uses `toJsonHook(a: T)` if it's in scope to
  ## customize serialization, see strtabs.toJsonHook for an example.
  when compiles(toJsonHook(a)): result = toJsonHook(a)
  elif T is Table | OrderedTable:
    result = newJObject()
    for k, v in pairs(a): result[k] = toJson(v)
  elif T is object | tuple:
    const isNamed = T is object or isNamedTuple(T)
    when isNamed:
      result = newJObject()
      for k, v in a.fieldPairs: result[k] = toJson(v)
    else:
      result = newJArray()
      for v in a.fields: result.add toJson(v)
  elif T is ref | ptr:
    if system.`==`(a, nil): result = newJNull()
    else: result = toJson(a[])
  elif T is array | seq:
    result = newJArray()
    for ai in a: result.add toJson(ai)
  elif T is pointer: result = toJson(cast[int](a))
    # edge case: `a == nil` could've also led to `newJNull()`, but this results
    # in simpler code for `toJson` and `fromJson`.
  elif T is distinct: result = toJson(a.distinctBase)
  elif T is bool: result = %(a)
  elif T is Ordinal: result = %(a.ord)
  else: result = %a
