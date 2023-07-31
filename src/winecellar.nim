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

import std/[httpclient, os, osproc, parsecfg, strutils, times]
import nuklear/nuklear_xlib
import wine, utils

const dtime: float = 20.0

proc main() =

  type ProgramState = enum
    mainMenu, newApp, newAppWine, newAppDownload, appExec, updateApp

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
  var installedApps: seq[string]
  # Create the program's configuration directory
  if not dirExists(configDir):
    createDir(configDir)
  # Or get the list of installed apps
  else:
    for file in walkFiles(configDir & "*.cfg"):
      var (_, name, _) = file.splitFile
      installedApps.add(name)

  var
    ctx = nuklearInit(800, 600, "Wine Cellar")
    showAbout, initialized, hidePopup, showAppsUpdate: bool = false
    state = mainMenu
    appData: array[4, array[1_024, char]]
    textLen: array[4, cint]
    wineVersion: cint = 0
    wineVersions: array[50, cstring]
    wineAmount = 0
    message, oldAppName, oldAppDir = ""
    secondThread: Thread[ThreadData]

  proc downloadInstaller(installerName: string) =
    try:
      state = newAppDownload
      message = "Downloading the application's installer."
      createThread(secondThread, downloadFile, @[installerName, cacheDir & "/" &
          installerName.split('/')[^1]])
    except HttpRequestError:
      message = "Can't download the program's installer."

  proc installApp(installerName: string) =
    var prefixDir = charArrayToString(appData[2])
    prefixDir = expandTilde(prefixDir)
    putEnv("WINEPREFIX", prefixDir)
    discard execCmd(getWineExec(wineVersions[wineVersion], versionInfo[^1]) &
        " " & installerName)
    appData[3] = appData[2]
    textLen[3] = textLen[2]
    state = appExec

  proc showAppEdit() =
    ctx.nk_layout_row_dynamic(0, 2)
    ctx.nk_label("Application name:", NK_TEXT_LEFT)
    discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData[0].unsafeAddr,
        textLen[0], 1_024, nk_filter_default)
    case state
    of newApp:
      ctx.nk_label("Windows installer:", NK_TEXT_LEFT)
      discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData[1].unsafeAddr,
          textLen[1], 1_024, nk_filter_default)
    of updateApp:
      ctx.nk_label("Executable path:", NK_TEXT_LEFT)
      discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData[3].unsafeAddr,
          textLen[3], 1_024, nk_filter_default)
    else:
      discard
    ctx.nk_label("Destination directory:", NK_TEXT_LEFT)
    discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData[2].unsafeAddr,
        textLen[2], 1_024, nk_filter_default)
    ctx.nk_label("Wine version:", NK_TEXT_LEFT)
    wineVersion = ctx.createCombo(wineVersions, wineVersion, 25, 200, 200, wineAmount)

  proc createFiles() =
    let
      wineExec = getWineExec(wineVersions[wineVersion], versionInfo[^1])
      appName = charArrayToString(appData[0])
      winePrefix = charArrayToString(appData[2])
    # Remove old files if they exist
    if oldAppName.len > 0:
      removeFile(configDir & appName & ".cfg")
      removeFile(homeDir & "/" & appName & ".sh")
      if oldAppDir != winePrefix:
        moveDir(oldAppDir, winePrefix)
      oldAppName = ""
      oldAppDir = ""
    var execPath = charArrayToString(appData[3])
    execPath = expandTilde(execPath)
    # Creating the configuration file for the application
    var newAppConfig = newConfig()
    newAppConfig.setSectionKey("", "prefix", winePrefix)
    newAppConfig.setSectionKey("", "exec", execPath)
    newAppConfig.setSectionKey("", "wine", wineExec)
    newAppConfig.writeConfig(configDir & appName & ".cfg")
    # Creating the shell script for the application
    writeFile(homeDir & "/" & appName & ".sh",
        "#!/bin/sh\nexport WINEPREFIX=\"" & winePrefix & "\"\n" &
        wineExec & " \"" & execPath & "\"")
    inclFilePermissions(homeDir & "/" & appName & ".sh", {fpUserExec})
    state = mainMenu

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
          if installedApps.len == 0:
            message = "No applications installed"
          else:
            showAppsUpdate = true
        if ctx.nk_button_label("Remove an existing application"):
          if installedApps.len == 0:
            message = "No applications installed"
          else:
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
        # Show the list of installed applications to update
        if showAppsUpdate:
          if ctx.createPopup(NK_POPUP_STATIC, "Update installed applicaion",
              nkWindowNoScrollbar, 275, 225, 255, ((installedApps.len + 1) * 32).cfloat):
            ctx.nk_layout_row_dynamic(25, 1)
            for app in installedApps:
              if ctx.nk_button_label(app.cstring):
                oldAppName = app
                (appData[0], textLen[0]) = stringToCharArray(app)
                let appConfig = loadConfig(configDir & app & ".cfg")
                (appData[3], textLen[3]) = stringToCharArray(
                    appConfig.getSectionValue("", "exec"))
                oldAppDir = appConfig.getSectionValue("", "prefix")
                (appData[2], textLen[2]) = stringToCharArray(oldAppDir)
                var wineExec = appConfig.getSectionValue("", "wine")
                if wineExec == "wine":
                  wineVersion = wineVersions.find("wine").cint
                  if wineVersion == -1:
                    wineVersion = wineVersions.find("wine-devel").cint
                elif wineExec.startsWith("/usr/local/wine-proton"):
                  wineVersion = wineVersions.find("wine-proton").cint
                else:
                  wineVersion = wineVersions.find(wineExec.split('/')[^3]).cint
                state = updateApp
                showAppsUpdate = false
                ctx.nk_popup_close
            if ctx.nk_button_label("Close"):
              showAppsUpdate = false
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
            (wineVersions, wineAmount) = getWineVersions()
            # Set the default values for a new Windows app
            for index, letter in "newApp":
              appData[0][index] = letter
            textLen[0] = 6
            for index, letter in homeDir & "/newApp":
              appData[2][index] = letter
            textLen[2] = homeDir.len.cint + 7
            textLen[3] = 1
            initialized = true
      # Installing a new Windows application and Wine if needed
      of newApp, newAppWine, newAppDownload:
        showAppEdit()
        var installerName = charArrayToString(appData[1])
        installerName = expandTilde(installerName)
        if state == newApp:
          if ctx.nk_button_label("Create"):
            # Check if all fields filled
            for length in textLen:
              if length == 0:
                message = "You have to fill all the fields."
            if message.len == 0:
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
                          wineVersion], versionInfo[^1], cacheDir, versionInfo[
                              0], dataDir])
                    except InstallError, HttpRequestError:
                      message = getCurrentExceptionMsg()
                # Download the installer if needed
                if installerName.startsWith("http") and state == newApp:
                  downloadInstaller(installerName)
                # Install the application
                if state == newApp:
                  installApp(installerName)
          if ctx.nk_button_label("Cancel"):
            state = mainMenu
        # Download the installer if needed, after installing Wine
        if state == newAppWine and installerName.startsWith("http") and
            not secondThread.running:
          downloadInstaller(installerName)
        # Install the application after downloading Wine or installer
        if state in {newAppWine, newAppDownload} and not secondThread.running:
          if state == newAppWine:
            installerName = charArrayToString(appData[1])
            installerName = expandTilde(installerName)
          else:
            installerName = cacheDir & "/" & installerName.split('/')[^1]
          installApp(installerName)
      # Setting a Windows application's executable
      of appExec:
        ctx.nk_layout_row_dynamic(0, 2)
        ctx.nk_label("Executable path:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData[3].unsafeAddr,
            textLen[3], 1_024, nk_filter_default)
        if ctx.nk_button_label("Set"):
          if textLen[3] == 0:
            message = "You have to enter the path to the executable file."
          if message.len == 0:
            var execPath = charArrayToString(appData[3])
            execPath = expandTilde(execPath)
            if not fileExists(execPath):
              message = "The selected file doesn't exist."
            else:
              createFiles()
              message = "The application installed."
        if ctx.nk_button_label("Cancel"):
          state = mainMenu
      # Update an installed application
      of updateApp:
        showAppEdit()
        if ctx.nk_button_label("Update"):
          # Check if all fields filled
          for length in textLen:
            if length == 0:
              message = "You have to fill all the fields."
          if message.len == 0:
            var execName = charArrayToString(appData[1])
            execName = expandTilde(execName)
            # If the user entered a path to file, check if exists
            if not fileExists(execName):
              message = "The selected executable doesn't exist."
            if message.len == 0:
              message = "Not implemented"
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
