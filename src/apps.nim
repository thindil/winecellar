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

## Various code related to Wine applications

import std/[httpclient, os, osproc, net, parsecfg, strutils]
import contracts
import wine, utils

type ApplicationData* = object
  ## The object to store information about the selected Wine application
  ##
  ## * name       - the name of the application, set by the user
  ## * installer  - the full path to the program's installer, used during
  ##                installation
  ## * directory  - the full path where the program's is or will be installed
  ## * executable - the name of the program's executable file to start the
  ##                program
  name*, installer*, directory*, executable*: string

proc installApp*(installerName: string; appData: ApplicationData; wineVersions,
    versionInfo: seq[string]; wineVersion: Natural): string {.raises: [],
    tags: [ReadIOEffect, ReadEnvEffect, WriteEnvEffect, ExecIOEffect,
        RootEffect], contractual.} =
  ## Install the selected application
  ##
  ## * installerName - the full path to the installer of an application
  ## * appData       - the information about the Wine's application which will
  ##                   be installed
  ## * wineVersions  - the available Wine versions
  ## * versionInfo   - the information about FreeBSD version
  ## * wineVersion   - the index of the selected Wine version
  ##
  ## Returns empty string if everything was ok, otherwise returns information
  ## what was wrong.
  require:
    installerName.len > 0
    appData.directory.len > 0
    wineVersions.len > wineVersion
  body:
    try:
      result = ""
      let prefixDir: string = expandTilde(path = appData.directory)
      putEnv(key = "WINEPREFIX", val = prefixDir)
      discard execCmd(command = getWineExec(wineVersion = wineVersions[
          wineVersion], arch = versionInfo[^1]) & " " & installerName)
    except OSError:
      result = "Can't install the application. Reason: " &
          getCurrentExceptionMsg()

proc downloadInstaller*(installerName: string; state: var ProgramState;
    message: var string; secondThread: var Thread[ThreadData]) {.raises: [],
    tags: [TimeEffect, ReadIOEffect, WriteIOEffect, RootEffect], contractual.} =
  ## Download the installer of an application
  ##
  ## * installerName - the name of the file of the installer to download
  ## * state         - the current state of the program
  ## * message       - the message to show to the user
  ## * secondThread  - the secondary thread on which the installer will be
  ##                   downloaded
  require:
    installerName.len > 0
    not secondThread.running
  body:
    try:
      state = newAppDownload
      message = "Downloading the application's installer."
      createThread(t = secondThread, tp = downloadFile, param = @[
          installerName, cacheDir & "/" & installerName.split(sep = '/')[^1]])
    except HttpRequestError, ValueError, TimeoutError, ProtocolError,
        OSError, IOError, Exception:
      message = "Can't download the program's installer. Reason: " &
          getCurrentExceptionMsg()

proc createFiles*(wineVersions, versionInfo: seq[string]; wineVersion: Natural;
    appData: var ApplicationData; oldAppName, oldAppDir, message: var string;
    state: var ProgramState) {.raises: [], tags: [ReadDirEffect, WriteIOEffect,
    ReadEnvEffect, ReadIOEffect], contractual.} =
  ## Create the configuration file and the executable file for the selected
  ## application. Delete old ones if they exists.
  body:
    try:
      let
        wineExec: string = getWineExec(wineVersion = wineVersions[
            wineVersion], arch = versionInfo[^1])
        appName: string = appData.name
        winePrefix: string = appData.directory
      # Remove old files if they exist
      if oldAppName.len > 0:
        removeFile(file = configDir & "/apps/" & oldAppName & ".cfg")
        removeFile(file = homeDir & "/" & oldAppName & ".sh")
        if oldAppDir != winePrefix:
          moveDir(source = oldAppDir, dest = winePrefix)
        oldAppName = ""
        oldAppDir = ""
      let executable: string = expandTilde(path = appData.executable)
      # Creating the configuration file for the application
      var newAppConfig: Config = newConfig()
      newAppConfig.setSectionKey(section = "General", key = "prefix",
          value = winePrefix)
      newAppConfig.setSectionKey(section = "General", key = "exec",
          value = executable)
      newAppConfig.setSectionKey(section = "General", key = "wine",
          value = wineExec)
      newAppConfig.writeConfig(filename = configDir & "/apps/" & appName & ".cfg")
      # Creating the shell script for the application
      writeFile(filename = homeDir & "/" & appName & ".sh",
          content = "#!/bin/sh\nexport WINEPREFIX=\"" & winePrefix &
          "\"\n" &
          wineExec & " \"" & winePrefix & "/drive_c/" & executable & "\"")
      inclFilePermissions(filename = homeDir & "/" & appName & ".sh",
          permissions = {fpUserExec})
      state = mainMenu
    except OSError, IOError, KeyError:
      message = "Can't create configuration files. Reason: " &
          getCurrentExceptionMsg()

