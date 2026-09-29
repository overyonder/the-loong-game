## Source-owned purpose attributes for enums. The declaration produces the enum
## and its description procedure from one definition, including judge builds.
import std/macros

macro describedEnum*(descriptionProc: untyped, declaration: untyped): untyped =
  let section = declaration[0]
  expectKind(section, nnkTypeSection)
  let definition = section[0]
  let name = if definition[0].kind == nnkPostfix: definition[0][
      1] else: definition[0]
  let enumType = definition[2]
  expectKind(enumType, nnkEnumTy)
  var branches = newTree(nnkCaseStmt, ident("value"))
  for index in 1 ..< enumType.len:
    let member = enumType[index]
    expectKind(member, nnkPragmaExpr)
    let attribute = member[1][0]
    if $attribute[0] != "purpose": error("Expected a purpose attribute", attribute)
    branches.add(newTree(nnkOfBranch, member[0], newStmtList(newTree(
        nnkReturnStmt, attribute[1]))))
    enumType[index] = member[0]
  result = newStmtList(section)
  result.add(newProc(newTree(nnkPostfix, ident("*"), descriptionProc),
    [ident("string"), newIdentDefs(ident("value"), name)], branches))
