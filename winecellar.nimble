# Package

version = "0.1.0"
author = "Bartek thindil Jasicki"
description = "A simple GUI to manage Windows programs on FreeBSD"
license = "BSD-3-Clause"
srcDir = "src"
bin = @["winecellar"]
binDir = "bin"


# Dependencies

requires "nim >= 1.6.12"
requires "contracts >= 0.2.2"

# Tasks

# Disable checking BareExcept warning for Nim 1.6.12
const warningFlags = (when (NimMajor, NimMinor, NimPatch) == (1, 6,
    12): "--warning:BareExcept:off " else: "")

task debug, "builds the project in debug mode":
  exec "nim c -d:debug -d:ssl --styleCheck:usages --spellSuggest:auto --errorMax:0 " &
      warningFlags & "--outdir:" & binDir & " " & srcDir & "/winecellar.nim"

task release, "builds the project in release mode":
  exec "nimble install -d -y"
  exec "nim c -d:release -d:ssl --passc:-flto --passl:-s " & warningFlags &
      "--outdir:" & binDir & " " & srcDir & "/winecellar.nim"

task test, "run the project unit tests":
  exec "testament all"
