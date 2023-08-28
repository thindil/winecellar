# Copyright © 2023 Bartek Jasicki
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met*:
# 1. Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
# 3. Neither the name of the copyright holder nor the
# names of its contributors may be used to endorse or promote products
# derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES *(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT *(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import std/[httpclient, json, os, osproc, net, strutils]
import contracts
import utils

const systemWine*: array[3, string] = ["wine", "wine-devel", "wine-proton"]

type
  InstallError* = object of CatchableError
  WineError* = object of CatchableError

let wineJsonFile* = cacheDir & "winefreesbie.json"

proc downloadWineList*(data: ThreadData) {.thread, nimcall, raises: [IOError,
    Exception], tags: [ReadDirEffect, ReadEnvEffect, ReadIOEffect,
    WriteIOEffect, TimeEffect, RootEffect], contractual.} =
  require:
    data.len == 4
  body:
    let client = newHttpClient(timeout = 5000)
    if data[1] == "amd64":
      client.downloadFile("https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
                data[0] & "-i386", data[2])
    client.downloadFile("https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
        data[0] & "-" & data[1], data[3])

proc installWine*(data: ThreadData) {.thread, nimcall, raises: [ValueError,
    TimeoutError, ProtocolError, OSError, IOError, InstallError, Exception],
    tags: [WriteIOEffect, TimeEffect, ReadIOEffect, ExecIOEffect, ReadEnvEffect,
    ReadDirEffect, RootEffect], contractual.} =
  require:
    data.len == 5
  body:
    let
      fileName = data[0] & ".pkg"
      client = newHttpClient(timeout = 5000)

    proc installWineVersion(arch: string) {.raises: [ValueError,
        HttpRequestError, InstallError, OSError, IOError, TimeoutError,
        Exception], tags: [WriteIOEffect, TimeEffect, ReadIOEffect,
        ExecIOEffect, RootEffect], contractual.} =
      require:
        arch.len > 0
      body:
        client.downloadFile("https://github.com/thindil/wine-freesbie/releases/download/" &
            data[3] & "-" & arch & "/" & fileName, data[2] & fileName)
        let (_, exitCode) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] &
            ":" & arch & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                data[4] &
            arch & " update")
        if exitCode != 0:
          raise newException(InstallError, "Can't create repository for Wine.")
        var (output, _) = execCmdEx("pkg info -d -q -F " & data[2] & fileName)
        output.stripLineEnd
        var dependencies = output.splitLines
        for depName in dependencies.mitems:
          let index = depName.rfind('-') - 1
          depName = depName[0..index]
        let (_, exitCode2) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] &
            ":" & arch & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                data[4] &
            arch & " install -Uy " & dependencies.join(" "))
        if exitCode2 != 0:
          raise newException(InstallError, "Can't install dependencies for Wine.")
        let (_, exitCode3) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] &
            ":" & arch & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                data[4] &
            arch & " clean -ay ")
        if exitCode3 != 0:
          raise newException(InstallError, "Can't remove downloaded dependencies for Wine.")
        if arch == "amd64":
          let (_, exitCode4) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] &
              ":i386" & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                  data[4] &
              "i386 install -Uy mesa-dri")
          if exitCode4 != 0:
            raise newException(InstallError, "Can't install mesa-dri 32-bit for Wine.")
          let (_, exitCode5) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] &
              ":i386" & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                  data[4] &
              "i386 clean -ay ")
          if exitCode5 != 0:
            raise newException(InstallError, "Can't remove downloaded dependencies formesa-dri 32-bit.")
        let workDir = getCurrentDir()
        setCurrentDir(data[2])
        let (_, exitCode6) = execCmdEx("tar xf " & data[0] & ".pkg")
        if exitCode6 != 0:
          raise newException(InstallError, "Can't decompress Wine package.")
        setCurrentDir(data[2] & "usr/local")
        var binPath = (if dirExists("wine-proton"): "wine-proton/" else: "")
        if arch == "amd64":
          binPath.add("bin/wine64.bin")
        else:
          binPath.add("bin/wine.bin")
        if execCmd("elfctl -e +noaslr " & binPath) != 0:
          raise newException(InstallError, "Can't disable ASLR for Wine.")
        if binPath.startsWith("wine-proton"):
          moveDir("wine-proton", data[0])
        else:
          createDir(data[0])
          moveDir("bin", data[0] & "/bin")
          moveDir("lib", data[0] & "/lib")
          moveDir("share", data[0] & "/share")
          removeDir("include")
          removeDir("libdata")
          removeDir("man")
        setCurrentDir(workDir)
        moveDir(data[2] & "usr/local/" & data[0], data[4] & arch &
            "/usr/local/" & data[0])
        removeDir(data[2] & "usr")
        removeFile(data[2] & data[0] & ".pkg")
        removeFile(data[2] & "+COMPACT_MANIFEST")
        removeFile(data[2] & "+MANIFEST")

    if data[1] == "amd64":
      installWineVersion("i386")
      installWineVersion("amd64")
      let wineFileName = data[4] & "amd64/usr/local/" &
          $data[0] & "/bin/wine"
      removeFile(wineFileName)
      client.downloadFile(
          "https://raw.githubusercontent.com/thindil/wine-freesbie/main/wine",
           wineFileName)
      inclFilePermissions(wineFileName, {fpUserExec})
    else:
      installWineVersion("i386")

proc getWineVersions*(): seq[string] {.raises: [WineError], tags: [
    WriteIOEffect, ReadIOEffect, ExecIOEffect, RootEffect], contractual.} =
  body:
    result = @[]
    for wineName in systemWine:
      if execCmd("pkg info -e " & wineName) == 0:
        result.add(wineName)
    let wineJson = try:
        parseFile(wineJsonFile)
      except ValueError, IOError, OSError, Exception:
        raise newException(WineError, "Can't parse the file with Wine versions. Reason: " &
            getCurrentExceptionMsg())
    try:
      for wineAsset in wineJson["assets"]:
        let name = wineAsset["name"].getStr()[0..^5]
        result.add(name)
    except KeyError:
      raise newException(WineError, "Can't parse the file with Wine versions. No information about them.")

proc getWineExec*(wineVersion, arch: string): string {.raises: [], tags: [],
    contractual.} =
  require:
    wineVersion.len > 0 and arch.len > 0
  ensure:
    result.len > 0
  body:
    return case $wineVersion
      of "wine", "wine-devel":
        "wine"
      of "wine-proton":
        "/usr/local/wine-proton/bin/wine"
      else:
        if arch == "amd64":
          dataDir & "amd64/usr/local/" & $wineVersion & "/bin/wine64"
        else:
          dataDir & "i386/usr/local/" & $wineVersion & "/bin/wine"
