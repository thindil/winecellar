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

import std/[httpclient, json, os, osproc, parsecfg, strutils, times]
import nuklear/nuklear_xlib

const
  dtime: float = 20.0
  systemWine: array[3, string] = ["wine", "wine-devel", "wine-proton"]

proc main() =

  type
    ProgramState = enum
      mainMenu, newApp, newAppWine, newAppDownload, appExec
    ThreadData = seq[string]
    InstallError = object of CatchableError

  let
    homeDir = getEnv("HOME")
    dataDir = homeDir & "/.local/share/winecellar/"
    configDir = homeDir & "/.config/winecellar/"
    cacheDir = homeDir & "/.cache/winecellar/"
    wineJsonFile = cacheDir & "winefreesbie.json"

  # Check the current version of FreeBSD
  var (output, _) = execCmdEx("uname -rm")
  output.stripLineEnd
  let versionInfo = output.split({' ', '-'})
  # Create the directory for temporary program's files
  if not fileExists(wineJsonFile):
    createDir(cacheDir)
  # Create directories for the program data
  if not dirExists(dataDir):
    createDir(dataDir & "i386/usr/share/keys")
    createSymlink("/usr/share/keys/pkg", dataDir & "i386/usr/share/keys/pkg")
    if versionInfo[^1] == "amd64":
      createDir(dataDir & "amd64/usr/share/keys")
      createSymlink("/usr/share/keys/pkg", dataDir & "amd64/usr/share/keys/pkg")
  # Create the program's configuration directory
  if not dirExists(configDir):
    createDir(configDir)

  var
    ctx = nuklearInit(800, 600, "Wine Cellar")
    showAbout, initialized, hidePopup: bool = false
    state = mainMenu
    newAppData: array[4, array[1_024, char]]
    textLen: array[4, cint]
    wineVersion: cint = 0
    wineVersions: array[50, cstring]
    wineAmount = 0
    message = ""
    secondThread: Thread[ThreadData]

  proc downloadWineList(data: ThreadData) {.thread, nimcall.} =
    let client = newHttpClient(timeout = 5000)
    if data[1] == "amd64":
      client.downloadFile("https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
                data[0] & "-i386", data[2])
    client.downloadFile("https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
        data[0] & "-" & data[1], data[3])

  proc installWine(data: ThreadData) {.thread, nimcall.} =
    let
      fileName = data[0] & ".pkg"
      client = newHttpClient(timeout = 5000)

    proc installWineVersion(arch: string) =
      client.downloadFile("https://github.com/thindil/wine-freesbie/releases/download/" &
          data[3] & "-" & arch & "/" & fileName, data[2] & fileName)
      let (_, exitCode) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] & ":" & arch &
          " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & data[4] &
          arch & " update")
      if exitCode != 0:
        raise newException(InstallError, "Can't create repository for Wine.")
      var (output, _) = execCmdEx("pkg info -d -q -F " & data[2] & fileName)
      output.stripLineEnd
      var dependencies = output.splitLines
      for depName in dependencies.mitems:
        let index = depName.rfind('-') - 1
        depName = depName[0..index]
      let (_, exitCode2) =  execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] & ":" & arch &
          " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & data[4] &
          arch & " install -Uy " & dependencies.join(" "))
      if exitCode2 != 0:
        raise newException(InstallError, "Can't install dependencies for Wine.")
      let (_, exitCode3) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] & ":" & arch &
          " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & data[4] &
          arch & " clean -ay ")
      if exitCode3 != 0:
        raise newException(InstallError, "Can't remove downloaded dependencies for Wine.")
      if arch == "amd64":
        let (_, exitCode4) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] & ":i386" &
            " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & data[4] &
            "i386 install -Uy mesa-dri")
        if exitCode4 != 0:
          raise newException(InstallError, "Can't install mesa-dri 32-bit for Wine.")
        let (_, exitCode5) = execCmdEx("pkg -o ABI=FreeBSD:" & data[3][0..1] & ":i386" &
            " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & data[4] &
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

  proc downloadFile(data: ThreadData) {.thread, nimcall.} =
    let client = newHttpClient(timeout = 5000)
    client.downloadFile(data[0], data[1])

  proc charArrayToString(charArray: openArray[char]): string =
    result = ""
    for ch in charArray:
      if ch == '\0':
        break
      result.add(ch)

  while true:
    let started = cpuTime()
    # Input
    if ctx.nuklearInput:
      break

    # GUI
    if ctx.createWin("Main", 0, 0, 800, 600, nkWindowNoScrollbar):
      case state
      # The main menu
      of mainMenu:
        ctx.nk_layout_row_dynamic(0, 1)
        if ctx.nk_button_label("Install a new application"):
          state = newApp
        if ctx.nk_button_label("Update an existing application"):
          message = "Not implemented"
        if ctx.nk_button_label("Remove an existing application"):
          message = "Not implemented"
        if ctx.nk_button_label("The program settings"):
          message = "Not implemented"
        if ctx.nk_button_label("About the program"):
          showAbout = true
        if ctx.nk_button_label("Quit"):
          break
        # The about program popup
        if showAbout:
          if ctx.createPopup(NK_POPUP_STATIC, "About the program",
              nkWindowNoScrollbar, 275, 225, 255, 150):
            ctx.nk_layout_row_dynamic(25, 1)
            ctx.nk_label("Simple program for managing Windows apps.", NK_TEXT_LEFT)
            ctx.nk_label("Version: 0.1", NK_TEXT_CENTERED)
            ctx.nk_label("(c) 2023 Bartek thindil Jasicki", NK_TEXT_CENTERED)
            ctx.nk_label("Released under BSD-3 license", NK_TEXT_CENTERED)
            if ctx.nk_button_label("Close"):
              showAbout = false
              ctx.nk_popup_close
            ctx.nk_popup_end
        # Initialize the program, download needed files and set the list of available Wine versions
        if not initialized:
          if not fileExists(wineJsonFile) and not secondThread.running:
            message = "Downloading Wine lists."
            try:
              createThread(secondThread, downloadWineList, @[versionInfo[0],
                  versionInfo[^1], cacheDir & "winefreesbie32.json", wineJsonFile])
            except HttpRequestError, ProtocolError:
              message = getCurrentExceptionMsg()
          if not secondThread.running:
            hidePopup = true
            # Build the list of available Wine versions
            for wineName in systemWine:
              if execCmd("pkg info -e " & wineName) == 0:
                wineVersions[wineAmount] = wineName.cstring
                wineAmount.inc
            let wineJson = parseFile(wineJsonFile)
            for wineAsset in wineJson["assets"]:
              let name = wineAsset["name"].getStr()[0..^5]
              wineVersions[wineAmount] = name.cstring
              wineAmount.inc
            # Set the default values for a new Windows app
            for index, letter in "newApp":
              newAppData[0][index] = letter
            textLen[0] = 6
            for index, letter in homeDir & "/newApp":
              newAppData[2][index] = letter
            textLen[2] = homeDir.len.cint + 7
            textLen[3] = 1
            initialized = true
      # Installing a new Windows application and Wine if needed
      of newApp, newAppWine, newAppDownload:
        ctx.nk_layout_row_dynamic(0, 2)
        ctx.nk_label("Application name:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE, newAppData[0].unsafeAddr,
            textLen[0], 1_024, nk_filter_default)
        ctx.nk_label("Windows installer:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE, newAppData[1].unsafeAddr,
            textLen[1], 1_024, nk_filter_default)
        ctx.nk_label("Destination directory:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE, newAppData[2].unsafeAddr,
            textLen[2], 1_024, nk_filter_default)
        ctx.nk_label("Wine version:", NK_TEXT_LEFT)
        wineVersion = createCombo(ctx, wineVersions, wineVersion, 25, 200, 200, wineAmount)
        if state == newApp:
          if ctx.nk_button_label("Create"):
            # Check if all fields filled
            for length in textLen:
              if length == 0:
                message = "You have to fill all the fields."
            if message.len == 0:
              var installerName = charArrayToString(newAppData[1])
              installerName = expandTilde(installerName)
              # If the user entered a path to file, check if exists
              if not installerName.startsWith("http"):
                if not fileExists(installerName):
                  message = "The application installer doesn't exist."
              if message.len == 0:
                # If Wine version isn't installed, download and install it
                if $wineVersions[wineVersion] notin systemWine:
                  if not dirExists(dataDir & "i386/usr/local/" & $wineVersions[wineVersion]):
                    message = "Installing the Wine and its dependencies."
                    state = newAppWine
                    try:
                      createThread(secondThread, installWine, @[$wineVersions[
                          wineVersion], versionInfo[^1], cacheDir, versionInfo[0], dataDir])
                    except InstallError, HttpRequestError:
                      message = getCurrentExceptionMsg()
                # Download the installer if needed
                if installerName.startsWith("http") and state == newApp:
                  try:
                    state = newAppDownload
                    message = "Downloading the application's installer."
                    createThread(secondThread, downloadFile, @[installerName, cacheDir & "/" &
                        installerName.split('/')[^1]])
                  except HttpRequestError:
                    message = "Can't download the program's installer."
                # Install the application
                if state == newApp:
                  var prefixDir = charArrayToString(newAppData[2])
                  prefixDir = expandTilde(prefixDir)
                  putEnv("WINEPREFIX", prefixDir)
                  let wineExec = case $wineVersions[wineVersion]
                    of "wine", "wine-devel":
                      "wine"
                    of "wine-proton":
                      "/usr/local/wine-proton/bin/wine"
                    else:
                      if versionInfo[^1] == "amd64":
                        dataDir & "amd64/usr/local/" & $wineVersions[
                            wineVersion] & "/bin/wine64"
                      else:
                        dataDir & "i386/usr/local/" & $wineVersions[wineVersion] & "/bin/wine"
                  discard execCmd(wineExec & " " & installerName)
                  newAppData[3] = newAppData[2]
                  textLen[3] = textLen[2]
                  state = appExec
          if ctx.nk_button_label("Cancel"):
            state = mainMenu
        var installerName = charArrayToString(newAppData[1])
        installerName = expandTilde(installerName)
        # Download the installer if needed, after installing Wine
        if state == newAppWine and installerName.startsWith("http") and not secondThread.running:
          try:
            state = newAppDownload
            message = "Downloading the application's installer."
            createThread(secondThread, downloadFile, @[installerName, cacheDir & "/" &
                installerName.split('/')[^1]])
          except HttpRequestError:
            message = "Can't download the program's installer."
        # Install the application after downloading Wine or installer
        if state in {newAppWine, newAppDownload} and not secondThread.running:
          if state == newAppWine:
            installerName = charArrayToString(newAppData[1])
            installerName = expandTilde(installerName)
          else:
            installerName = cacheDir & "/" & installerName.split('/')[^1]
          var prefixDir = charArrayToString(newAppData[2])
          prefixDir = expandTilde(prefixDir)
          putEnv("WINEPREFIX", prefixDir)
          let wineExec = case $wineVersions[wineVersion]
            of "wine", "wine-devel":
              "wine"
            of "wine-proton":
              "/usr/local/wine-proton/bin/wine"
            else:
              if versionInfo[^1] == "amd64":
                dataDir & "amd64/usr/local/" & $wineVersions[
                    wineVersion] & "/bin/wine64"
              else:
                dataDir & "i386/usr/local/" & $wineVersions[wineVersion] & "/bin/wine"
          discard execCmd(wineExec & " " & installerName)
          newAppData[3] = newAppData[2]
          textLen[3] = textLen[2]
          state = appExec
      # Setting a Windows application's executable
      of appExec:
        ctx.nk_layout_row_dynamic(0, 2)
        ctx.nk_label("Executable path:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE, newAppData[3].unsafeAddr,
            textLen[3], 1_024, nk_filter_default)
        if ctx.nk_button_label("Set"):
          if textLen[3] == 0:
            message = "You have to enter the path to the executable file."
          if message.len == 0:
            var execPath = charArrayToString(newAppData[3])
            execPath = expandTilde(execPath)
            if not fileExists(execPath):
              message = "The selected file doesn't exist."
            else:
              let
                wineExec = case $wineVersions[wineVersion]
                  of "wine", "wine-devel":
                    "wine"
                  of "wine-proton":
                    "/usr/local/wine-proton/bin/wine"
                  else:
                    if versionInfo[^1] == "amd64":
                      dataDir & "amd64/usr/local/" & $wineVersions[
                          wineVersion] & "/bin/wine64"
                    else:
                      dataDir & "i386/usr/local/" & $wineVersions[wineVersion] & "/bin/wine"
                appName = charArrayToString(newAppData[0])
                winePrefix = charArrayToString(newAppData[2])
              # Creating the configuration file for the application
              var newAppConfig = newConfig()
              newAppConfig.setSectionKey("", "prefix", winePrefix)
              newAppConfig.setSectionKey("", "exec", execPath)
              newAppConfig.setSectionKey("", "wine", wineExec)
              newAppConfig.writeConfig(configDir & appName & ".cfg")
              # Creating the shell script for the application
              writeFile(homeDir & "/" & appName & ".sh",
                  "#!/bin/sh\nexport WINEPREFIX=\"" & winePrefix & "\"\n" &
                  wineexec & " \"" & execPath & "\"")
              inclFilePermissions(homeDir & "/" & appName & ".sh", {fpUserExec})
              message = "The application installed."
              state = mainMenu
        if ctx.nk_button_label("Cancel"):
          state = mainMenu
      # The message popup
      if message.len > 0 or hidePopup:
        if ctx.createPopup(NK_POPUP_STATIC, "Info", nkWindowNoScrollbar, 275,
            225, ctx.getTextWidth(message.cstring) + 10.0, 80):
          ctx.nk_layout_row_dynamic(25, 1)
          ctx.nk_label(message.cstring, NK_TEXT_LEFT)
          if ctx.nk_button_label("Close") or hidePopup:
            message = ""
            hidePopup = false
            ctx.nk_popup_close
          ctx.nk_popup_end
    ctx.nk_end

    # Draw
    nuklearDraw()

    # Timing
    let dt = cpuTime() - started
    if (dt < dtime):
      sleep((dtime - dt).int)

  nuklearClose()

main()
