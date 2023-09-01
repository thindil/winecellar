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

## Provides code to manipulate Wine versions, like download, install or get
## information about it.

import std/[httpclient, json, os, osproc, net, strutils]
import contracts
import utils

const systemWine*: array[3, string] = ["wine", "wine-devel", "wine-proton"]
  ## The list of versions of Wine available as system's packages

type
  InstallError* = object of CatchableError
    ## Raised when there is a problem during installation of Wine
  WineError* = object of CatchableError
    ## Raised when there is a problem with getting information about Wine

let wineJsonFile*: string = cacheDir & "winefreesbie.json"

proc downloadWineList*(data: ThreadData) {.thread, nimcall, raises: [IOError,
    Exception], tags: [ReadDirEffect, ReadEnvEffect, ReadIOEffect,
    WriteIOEffect, TimeEffect, RootEffect], contractual.} =
  ## Download the list of available Wine versions for the selected FreeBSD
  ## version from Wine-Freesbie project
  ##
  ## * data - the array of data needed for download: 0 - FreeBSD version,
  ##          1 - CPU architecture, 2 - file name for 32-bit list, 3 - file
  ##          name for 64-bit list
  require:
    data.len == 4
  body:
    let client: HttpClient = newHttpClient(timeout = 5000)
    if data[1] == "amd64":
      client.downloadFile(url = "https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
                data[0] & "-i386", filename = data[2])
    client.downloadFile(url = "https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
        data[0] & "-" & data[1], filename = data[3])

proc installWine*(data: ThreadData) {.thread, nimcall, raises: [ValueError,
    TimeoutError, ProtocolError, OSError, IOError, InstallError, Exception],
    tags: [WriteIOEffect, TimeEffect, ReadIOEffect, ExecIOEffect, ReadEnvEffect,
    ReadDirEffect, RootEffect], contractual.} =
  ## Installing the selected Wine and its dependencies, on 64-bit systems it
  ## also install 32-bit version of Wine
  ##
  ## * data - the array of data needed for the installation: 0 - Wine version,
  ##          1 - CPU architecture, 2 - the program's cache directory path,
  ##          3 - FreeBSD version, 4 - the program's data directory path
  require:
    data.len == 5
  body:
    let
      fileName: string = data[0] & ".pkg"
      client: HttpClient = newHttpClient(timeout = 5000)

    proc installWineVersion(arch: string) {.raises: [ValueError,
        HttpRequestError, InstallError, OSError, IOError, TimeoutError,
        Exception], tags: [WriteIOEffect, TimeEffect, ReadIOEffect,
        ExecIOEffect, RootEffect], contractual.} =
      ## Install the selected version of Wine and its dependencies
      ##
      ## * arch - CPU architecture for which Wine will be installed
      require:
        arch.len > 0
      body:
        client.downloadFile(url = "https://github.com/thindil/wine-freesbie/releases/download/" &
            data[3] & "-" & arch & "/" & fileName, filename = data[2] & fileName)
        let (_, exitCode) = execCmdEx(command = "pkg -o ABI=FreeBSD:" & data[3][
            0..1] & ":" & arch & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                data[4] &
            arch & " update")
        if exitCode != 0:
          raise newException(exceptn = InstallError,
              message = "Can't create repository for Wine.")
        var (output, _) = execCmdEx(command = "pkg info -d -q -F " & data[2] & fileName)
        output.stripLineEnd
        var dependencies: seq[string] = output.splitLines
        for depName in dependencies.mitems:
          let index: int = depName.rfind(sub = '-') - 1
          depName = depName[0..index]
        let (_, exitCode2) = execCmdEx(command = "pkg -o ABI=FreeBSD:" & data[
            3][0..1] & ":" & arch & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
            data[4] & arch & " install -Uy " & dependencies.join(sep = " "))
        if exitCode2 != 0:
          raise newException(exceptn = InstallError,
              message = "Can't install dependencies for Wine.")
        let (_, exitCode3) = execCmdEx(command = "pkg -o ABI=FreeBSD:" & data[
            3][0..1] & ":" & arch & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
                data[4] & arch & " clean -ay ")
        if exitCode3 != 0:
          raise newException(exceptn = InstallError,
              message = "Can't remove downloaded dependencies for Wine.")
        if arch == "amd64":
          let (_, exitCode4) = execCmdEx(command = "pkg -o ABI=FreeBSD:" & data[
              3][0..1] & ":i386" & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
              data[4] & "i386 install -Uy mesa-dri")
          if exitCode4 != 0:
            raise newException(exceptn = InstallError,
                message = "Can't install mesa-dri 32-bit for Wine.")
          let (_, exitCode5) = execCmdEx(command = "pkg -o ABI=FreeBSD:" & data[
              3][0..1] & ":i386" & " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " &
              data[4] & "i386 clean -ay ")
          if exitCode5 != 0:
            raise newException(exceptn = InstallError,
                message = "Can't remove downloaded dependencies formesa-dri 32-bit.")
        let workDir: string = getCurrentDir()
        setCurrentDir(newDir = data[2])
        let (_, exitCode6) = execCmdEx(command = "tar xf " & data[0] & ".pkg")
        if exitCode6 != 0:
          raise newException(exceptn = InstallError,
              message = "Can't decompress Wine package.")
        setCurrentDir(newDir = data[2] & "usr/local")
        var binPath: string = (if dirExists(
            dir = "wine-proton"): "wine-proton/" else: "")
        if arch == "amd64":
          binPath.add(y = "bin/wine64.bin")
        else:
          binPath.add(y = "bin/wine.bin")
        if execCmd(command = "elfctl -e +noaslr " & binPath) != 0:
          raise newException(exceptn = InstallError,
              message = "Can't disable ASLR for Wine.")
        if binPath.startsWith(prefix = "wine-proton"):
          moveDir(source = "wine-proton", dest = data[0])
        else:
          createDir(dir = data[0])
          moveDir(source = "bin", dest = data[0] & "/bin")
          moveDir(source = "lib", dest = data[0] & "/lib")
          moveDir(source = "share", dest = data[0] & "/share")
          removeDir(dir = "include")
          removeDir(dir = "libdata")
          removeDir(dir = "man")
        setCurrentDir(newDir = workDir)
        moveDir(source = data[2] & "usr/local/" & data[0], dest = data[4] &
            arch & "/usr/local/" & data[0])
        removeDir(dir = data[2] & "usr")
        removeFile(file = data[2] & data[0] & ".pkg")
        removeFile(file = data[2] & "+COMPACT_MANIFEST")
        removeFile(file = data[2] & "+MANIFEST")

    if data[1] == "amd64":
      installWineVersion(arch = "i386")
      installWineVersion(arch = "amd64")
      let wineFileName: string = data[4] & "amd64/usr/local/" &
          $data[0] & "/bin/wine"
      removeFile(file = wineFileName)
      client.downloadFile(url = "https://raw.githubusercontent.com/thindil/wine-freesbie/main/wine",
           filename = wineFileName)
      inclFilePermissions(filename = wineFileName, permissions = {fpUserExec})
    else:
      installWineVersion(arch = "i386")

proc getWineVersions*(): seq[string] {.raises: [WineError], tags: [
    WriteIOEffect, ReadIOEffect, ExecIOEffect, RootEffect], contractual.} =
  ## Get the list of available Wine versions
  ##
  ## Returns sequence of strings with names of available Wine versions
  body:
    result = @[]
    for wineName in systemWine:
      if execCmd(command = "pkg info -e " & wineName) == 0:
        result.add(y = wineName)
    let wineJson: JsonNode = try:
        parseFile(filename = wineJsonFile)
      except ValueError, IOError, OSError, Exception:
        raise newException(exceptn = WineError,
            message = "Can't parse the file with Wine versions. Reason: " &
            getCurrentExceptionMsg())
    try:
      for wineAsset in wineJson["assets"]:
        let name: string = wineAsset["name"].getStr()[0..^5]
        result.add(y = name)
    except KeyError:
      raise newException(exceptn = WineError,
          message = "Can't parse the file with Wine versions. No information about them.")

proc getWineExec*(wineVersion, arch: string): string {.raises: [], tags: [],
    contractual.} =
  ## Get the name of executable for the selected Wine version
  ##
  ## * wineVersion - the version of Wine which executable is looking for
  ## * arch        - CPU architecture to look for the executable
  ##
  ## Returns the full path to the Wine executable file
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
