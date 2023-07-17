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

import std/[httpclient, json, os, osproc, strutils, times]
import nuklear/nuklear_xlib

const
  dtime: float = 20.0
  systemWine: array[3, string] = ["wine", "wine-devel", "wine-proton"]

proc main() =

  type ProgramState = enum
    mainMenu, newApp, appExec

  let
    homeDir = getEnv("HOME")
    dataDir = homeDir & "/.local/share/winecellar/"
    configDir = homeDir & "/.config/winecellar/"

  # Download the list of available wine-freesbie versions
  let
    cacheDir = homeDir & "/.cache/winecellar/"
    wineJsonFile = cacheDir & "winefreesbie.json"
  var (output, _) = execCmdEx("uname -rm")
  output.stripLineEnd
  let versionInfo = output.split({' ', '-'})
  if not fileExists(wineJsonFile):
    createDir(cacheDir)
    let client = newHttpClient(timeout = 5000)
    try:
      writeFile(wineJsonFile, client.getContent(
          "https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
          versionInfo[0] & "-" & versionInfo[^1]))
      if versionInfo[^1] == "amd64":
        writeFile(cacheDir & "winefreesbie32.json", client.getContent(
            "https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
            versionInfo[0] & "-i386"))
    except HttpRequestError:
      discard
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
    showAbout: bool = false
    state = mainMenu
    newAppData: array[4, array[1_024, char]]
    textLen: array[4, cint]
    wineVersion: cint = 0
    wineVersions: array[50, cstring]
    wineAmount = 0
    message = ""

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

  proc installWine(arch, version: string): string =
    result = ""
    if execCmd("fetch -o " & cacheDir &
        " https://github.com/thindil/wine-freesbie/releases/download/" &
        versionInfo[0] & "-" & arch & "/" &
        $version & ".pkg") != 0:
      return "Can't download the selected version of Wine."
    if execCmd("pkg -o ABI=FreeBSD:" & versionInfo[0][0..1] & ":" & arch &
        " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & dataDir &
        arch & " update") != 0:
      return "Can't create repository for Wine."
    var (output, _) = execCmdEx("pkg info -d -q -F " & cacheDir & version & ".pkg")
    output.stripLineEnd
    var dependencies = output.splitLines
    for depName in dependencies.mitems:
      let index = depName.rfind('-') - 1
      depName = depName[0..index]
    if execCmd("pkg -o ABI=FreeBSD:" & versionInfo[0][0..1] & ":" & arch &
        " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & dataDir &
        arch & " install -Uy " & dependencies.join(" ")) != 0:
      return "Can't install dependencies for Wine."
    if execCmd("pkg -o ABI=FreeBSD:" & versionInfo[0][0..1] & ":" & arch &
        " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & dataDir &
        arch & " clean -ay ") != 0:
      return "Can't remove downloaded dependencies for Wine."
    if arch == "amd64":
      if execCmd("pkg -o ABI=FreeBSD:" & versionInfo[0][0..1] & ":i386" &
          " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & dataDir &
          "i386 install -Uy mesa-dri") != 0:
        return "Can't install mesa-dri 32-bit for Wine."
      if execCmd("pkg -o ABI=FreeBSD:" & versionInfo[0][0..1] & ":i386" &
          " -o INSTALL_AS_USER=true -o RUN_SCRIPTS=false --rootdir " & dataDir &
          "i386 clean -ay ") != 0:
        return "Can't remove downloaded dependencies formesa-dri 32-bit."
    let workDir = getCurrentDir()
    setCurrentDir(cacheDir)
    if execCmd("tar xf " & version & ".pkg") != 0:
      return "Can't decompress Wine package."
    setCurrentDir(cacheDir & "usr/local")
    var binPath = (if dirExists("wine-proton"): "wine-proton/" else: "")
    if arch == "amd64":
      binPath.add("bin/wine64.bin")
    else:
      binPath.add("bin/wine.bin")
    if execCmd("elfctl -e +noaslr " & binPath) != 0:
      return "Can't disable ASLR for Wine."
    if binPath.startsWith("wine-proton"):
      moveDir("wine-proton", version)
    else:
      createDir(version)
      moveDir("bin", version & "/bin")
      moveDir("lib", version & "/lib")
      moveDir("share", version & "/share")
      removeDir("include")
      removeDir("libdata")
      removeDir("man")
    setCurrentDir(workDir)
    moveDir(cacheDir & "usr/local/" & version, dataDir & arch & "/usr/local/" & version)
    removeDir(cacheDir & "usr")
    removeFile(cacheDir & version & ".pkg")
    removeFile(cacheDir & "+COMPACT_MANIFEST")
    removeFile(cacheDir & "+MANIFEST")

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
      of newApp:
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
        if ctx.nk_button_label("Create"):
          # Check if all fields filled
          for length in textLen:
            if length == 0:
              message = "You have to fill all the fields."
          if message.len == 0:
            var installerName = ""
            for ch in newAppData[1]:
              if ch == '\0':
                break
              installerName.add(ch)
            installerName = expandTilde(installerName)
            # If the user entered a path to file, check if exists
            if not installerName.startsWith("http"):
              if not fileExists(installerName):
                message = "The application installer doesn't exist."
            if message.len == 0:
              # If Wine version isn't installed, download and install it
              if $wineVersions[wineVersion] notin systemWine and not dirExists(
                  dataDir & "i386/usr/local/" & $wineVersions[wineVersion]):
                message = installWine("i386", $wineVersions[wineVersion])
                if message.len == 0 and versionInfo[^1] == "amd64":
                  message = installWine("amd64", $wineVersions[wineVersion])
                  # Install the Freesbie version of Wine startup script
                  let
                    client = newHttpClient(timeout = 5000)
                    wineFileName = dataDir & "amd64/usr/local/" & $wineVersions[
                        wineVersion] & "/bin/wine"
                  try:
                    removeFile(wineFileName)
                    writeFile(wineFileName, client.getContent("https://raw.githubusercontent.com/thindil/wine-freesbie/main/wine"))
                    inclFilePermissions(wineFileName, {fpUserExec})
                  except HttpRequestError:
                    message = getCurrentExceptionMsg()
                # Download the installer if needed
              if message.len == 0 and installerName.startsWith("http"):
                discard
                if execCmd("fetch -o " & cacheDir & " " & installerName) != 0:
                  message = "Can't download the program's installer."
                else:
                  installerName = cacheDir & "/" & installerName.split('/')[^1]
              # Install the application
              if message.len == 0:
                var prefixDir = ""
                for ch in newAppData[2]:
                  if ch == '\0':
                    break
                  prefixDir.add(ch)
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
      of appExec:
        ctx.nk_layout_row_dynamic(0, 2)
        ctx.nk_label("Executable path:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE, newAppData[3].unsafeAddr,
            textLen[3], 1_024, nk_filter_default)
        if ctx.nk_button_label("Set"):
          if textLen[3] == 0:
            message = "You have to enter the path to the executable file."
          if message.len == 0:
            var execPath = ""
            for ch in newAppData[3]:
              if ch == '\0':
                break
              execPath.add(ch)
            execPath = expandTilde(execPath)
            if not fileExists(execPath):
              message = "The selected file doesn't exist."
        if ctx.nk_button_label("Cancel"):
          state = mainMenu
      # The message popup
      if message.len > 0:
        if ctx.createPopup(NK_POPUP_STATIC, "Info", nkWindowNoScrollbar, 275,
            225, ctx.getTextWidth(message.cstring) + 10.0, 80):
          ctx.nk_layout_row_dynamic(25, 1)
          ctx.nk_label(message.cstring, NK_TEXT_LEFT)
          if ctx.nk_button_label("Close"):
            message = ""
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
