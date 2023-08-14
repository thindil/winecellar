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

  type
    ProgramState = enum
      mainMenu, newApp, newAppWine, newAppDownload, appExec, updateApp, appSettings

    ApplicationData = object
      name: array[1_024, char]
      installer: array[1_024, char]
      directory: array[1_024, char]
      executable: array[1_024, char]

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
  var
    installedApps: seq[string]
    wineIntervals: array[3, cstring] = ["daily", "weekly", "monthly"]
    wineRefresh: cint = 1
    wineLastCheck = now() - 2.years
  # Create the program's configuration directory
  if not dirExists(configDir):
    createDir(configDir & "/apps")
  # Or get the list of installed apps and the program's configuration
  else:
    let programConfig = loadConfig(configDir & "winecellar.cfg")
    wineRefresh = wineIntervals.find(programConfig.getSectionValue("Wine",
        "interval")).cint
    wineLastCheck = programConfig.getSectionValue("Wine", "lastCheck").parse("yyyy-MM-dd'T'HH:mm:sszzz")
    let deleteWineList = case wineRefresh
      of 0:
        now() - 1.days > wineLastCheck
      of 1:
        now() - 1.weeks > wineLastCheck
      of 2:
        now() - 1.months > wineLastCheck
      else:
        false
    if deleteWineList:
      removeFile(wineJsonFile)
    for file in walkFiles(configDir & "/apps/" & "*.cfg"):
      var (_, name, _) = file.splitFile
      installedApps.add(name)

  var
    ctx = nuklearInit(800, 600, "Wine Cellar")
    showAbout, initialized, hidePopup, showAppsUpdate, showAppsDelete,
      confirmDelete: bool = false
    state = mainMenu
    appData: ApplicationData
    textLen: array[4, cint]
    wineVersion: cint = 0
    wineVersions: array[50, cstring]
    wineAmount = 0
    message, oldAppName, oldAppDir = ""
    secondThread: Thread[ThreadData]
    oldWineRefresh = wineRefresh

  proc downloadInstaller(installerName: string) =
    try:
      state = newAppDownload
      message = "Downloading the application's installer."
      createThread(secondThread, downloadFile, @[installerName, cacheDir & "/" &
          installerName.split('/')[^1]])
    except HttpRequestError:
      message = "Can't download the program's installer."

  proc installApp(installerName: string) =
    var prefixDir = charArrayToString(appData.directory)
    prefixDir = expandTilde(prefixDir)
    putEnv("WINEPREFIX", prefixDir)
    discard execCmd(getWineExec(wineVersions[wineVersion], versionInfo[^1]) &
        " " & installerName)
    textLen[3] = 0
    state = appExec

  proc showAppEdit() =
    ctx.nk_layout_row_dynamic(0, 2)
    ctx.nk_label("Application name:", NK_TEXT_LEFT)
    discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData.name.unsafeAddr,
        textLen[0], appData.name.len.cint, nk_filter_default)
    case state
    of newApp:
      ctx.nk_label("Windows installer:", NK_TEXT_LEFT)
      discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData.installer.unsafeAddr,
          textLen[1], appData.installer.len.cint, nk_filter_default)
      ctx.nk_label("Destination directory:", NK_TEXT_LEFT)
    of updateApp:
      ctx.nk_label("Executable path:", NK_TEXT_LEFT)
      discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData.executable.unsafeAddr,
          textLen[3], appData.executable.len.cint, nk_filter_default)
      ctx.nk_label("Wine directory:", NK_TEXT_LEFT)
    else:
      discard
    discard ctx.nk_edit_string(NK_EDIT_SIMPLE, appData.directory.unsafeAddr,
        textLen[2], appData.directory.len.cint, nk_filter_default)
    ctx.nk_label("Wine version:", NK_TEXT_LEFT)
    wineVersion = ctx.createCombo(wineVersions, wineVersion, 25, 200, 200, wineAmount)

  proc createFiles() =
    let
      wineExec = getWineExec(wineVersions[wineVersion], versionInfo[^1])
      appName = charArrayToString(appData.name)
      winePrefix = charArrayToString(appData.directory)
    # Remove old files if they exist
    if oldAppName.len > 0:
      removeFile(configDir & "/apps/" & oldAppName & ".cfg")
      removeFile(homeDir & "/" & oldAppName & ".sh")
      if oldAppDir != winePrefix:
        moveDir(oldAppDir, winePrefix)
      oldAppName = ""
      oldAppDir = ""
    var executable = charArrayToString(appData.executable)
    executable = expandTilde(executable)
    # Creating the configuration file for the application
    var newAppConfig = newConfig()
    newAppConfig.setSectionKey("General", "prefix", winePrefix)
    newAppConfig.setSectionKey("General", "exec", executable)
    newAppConfig.setSectionKey("General", "wine", wineExec)
    newAppConfig.writeConfig(configDir & "/apps/" & appName & ".cfg")
    # Creating the shell script for the application
    writeFile(homeDir & "/" & appName & ".sh",
        "#!/bin/sh\nexport WINEPREFIX=\"" & winePrefix & "\"\n" &
        wineExec & " \"" & winePrefix & "/drive_c/" & executable & "\"")
    inclFilePermissions(homeDir & "/" & appName & ".sh", {fpUserExec})
    state = mainMenu

  proc showInstalledApps(updating: bool = true) =
    ctx.nk_layout_row_dynamic(25, 1)
    for app in installedApps:
      if ctx.nk_button_label(app.cstring):
        oldAppName = app
        (appData.name, textLen[0]) = stringToCharArray(app)
        let appConfig = loadConfig(configDir & "/apps/" & app & ".cfg")
        (appData.executable, textLen[3]) = stringToCharArray(
            appConfig.getSectionValue("General", "exec"))
        oldAppDir = appConfig.getSectionValue("General", "prefix")
        (appData.directory, textLen[2]) = stringToCharArray(oldAppDir)
        var wineExec = appConfig.getSectionValue("General", "wine")
        if wineExec == "wine":
          wineVersion = wineVersions.find("wine").cint
          if wineVersion == -1:
            wineVersion = wineVersions.find("wine-devel").cint
        elif wineExec.startsWith("/usr/local/wine-proton"):
          wineVersion = wineVersions.find("wine-proton").cint
        else:
          wineVersion = wineVersions.find(wineExec.split('/')[^3]).cint
        if updating:
          state = updateApp
          showAppsUpdate = false
        else:
          showAppsDelete = false
          confirmDelete = true
        ctx.nk_popup_close
    if ctx.nk_button_label("Close"):
      if updating:
        showAppsUpdate = false
      else:
        showAppsDelete = false
      ctx.nk_popup_close

  while true:
    let started = cpuTime()
    # Input
    if nuklearInput():
      break

    # GUI
    showWindow("Main", 0, 0, 800, 600, {windowNoScrollbar}):
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
            showAppsDelete = true
        if ctx.nk_button_label("The program settings"):
          state = appSettings
        if ctx.nk_button_label("About the program"):
          showAbout = true
        if ctx.nk_button_label("Quit"):
          break
        # The about program popup
        if showAbout:
          showPopup(staticPopup, "About the program", {windowNoScrollbar}, 275,
              225, 255, 150):
            ctx.nk_layout_row_dynamic(25, 1)
            ctx.nk_label("Simple program for managing Windows apps.", NK_TEXT_LEFT)
            ctx.nk_label("Version: 0.1", NK_TEXT_CENTERED)
            ctx.nk_label("(c) 2023 Bartek thindil Jasicki", NK_TEXT_CENTERED)
            ctx.nk_label("Released under BSD-3 license", NK_TEXT_CENTERED)
            if ctx.nk_button_label("Close"):
              showAbout = false
              ctx.nk_popup_close
        # Show the list of installed applications to update
        if showAppsUpdate:
          showPopup(staticPopup, "Update installed application", {
              windowNoScrollbar}, 275, 225, 255, ((installedApps.len + 1) * 32).float):
            showInstalledApps()
        # Show the list of installed applications to delete
        elif showAppsDelete:
          showPopup(staticPopup, "Delete installed applicaion", {
              windowNoScrollbar}, 275, 225, 255, ((installedApps.len + 1) * 32).float):
            showInstalledApps(false)
        # Show confirmation dialog for delete an installed app
        elif confirmDelete:
          showPopup(staticPopup, "Delete installed application", {
              windowNoScrollbar}, 275, 225, 255, 75):
            ctx.nk_layout_row_dynamic(25, 1)
            ctx.nk_label(("Are you sure to delete application '" &
                charArrayToString(appData.name) & "'?").cstring, NK_TEXT_LEFT)
            ctx.nk_layout_row_dynamic(25, 2)
            if ctx.nk_button_label("Yes"):
              removeDir(charArrayToString(appData.directory))
              let appName = charArrayToString(appData.name)
              removeFile(homeDir & "/" & appName & ".sh")
              removeFile(configDir & "/apps/" & appName & ".cfg")
              confirmDelete = false
              message = "The application deleted."
            if ctx.nk_button_label("No"):
              confirmDelete = false
        # Initialize the program, download needed files and set the list of available Wine versions
        if not initialized:
          if not fileExists(wineJsonFile) and not secondThread.running:
            wineLastCheck = now()
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
              appData.name[index] = letter
            textLen[0] = 6
            for index, letter in homeDir & "/newApp":
              appData.directory[index] = letter
            textLen[2] = homeDir.len.cint + 7
            textLen[3] = 1
            initialized = true
      # Installing a new Windows application and Wine if needed
      of newApp, newAppWine, newAppDownload:
        showAppEdit()
        var installerName = charArrayToString(appData.installer)
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
            installerName = charArrayToString(appData.installer)
            installerName = expandTilde(installerName)
          else:
            installerName = cacheDir & "/" & installerName.split('/')[^1]
          installApp(installerName)
      # Setting a Windows application's executable
      of appExec:
        ctx.nk_layout_row_dynamic(0, 2)
        ctx.nk_label("Executable path:", NK_TEXT_LEFT)
        discard ctx.nk_edit_string(NK_EDIT_SIMPLE,
            appData.executable.unsafeAddr, textLen[3], 1_024, nk_filter_default)
        if ctx.nk_button_label("Set"):
          if textLen[3] == 0:
            message = "You have to enter the path to the executable file."
          if message.len == 0:
            var executable = charArrayToString(appData.directory) &
                "/drive_c/" & charArrayToString(appData.executable)
            executable = expandTilde(executable)
            if not fileExists(executable):
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
          textLen[1] = 1
          # Check if all fields filled
          for length in textLen:
            if length == 0:
              message = "You have to fill all the fields."
          if message.len == 0:
            var execName = oldAppDir & "/drive_c/" & charArrayToString(
                appData.executable)
            execName = expandTilde(execName)
            # If the user entered a path to file, check if exists
            if not fileExists(execName):
              message = "The selected executable doesn't exist."
            if message.len == 0:
              createFiles()
              message = "The application updated."
        if ctx.nk_button_label("Cancel"):
          state = mainMenu
      # The program's settings
      of appSettings:
        ctx.nk_layout_row_dynamic(0, 2)
        ctx.nk_label("Wine list check:", NK_TEXT_LEFT)
        wineRefresh = ctx.createCombo(wineIntervals, wineRefresh, 25, 200, 200)
        if ctx.nk_button_label("Save"):
          state = mainMenu
        if ctx.nk_button_label("Cancel"):
          wineRefresh = oldWineRefresh
          state = mainMenu
      # The message popup
      if message.len > 0 or hidePopup:
        showPopup(staticPopup, "Info", {windowNoScrollbar}, 275, 225,
            ctx.getTextWidth(message.cstring) + 10.0, 80):
          ctx.nk_layout_row_dynamic(25, 1)
          ctx.nk_label(message.cstring, NK_TEXT_LEFT)
          if ctx.nk_button_label("Close") or hidePopup:
            message = ""
            hidePopup = false
            ctx.nk_popup_close

    # Draw
    nuklearDraw()

    # Timing
    let dt = cpuTime() - started
    if (dt < dtime):
      sleep((dtime - dt).int)

  # Creating the configuration file for the application
  var newProgramConfig = newConfig()
  newProgramConfig.setSectionKey("Wine", "interval", $wineIntervals[wineRefresh])
  newProgramConfig.setSectionKey("Wine", "lastCheck", $wineLastCheck)
  newProgramConfig.writeConfig(configDir & "winecellar.cfg")
  nuklearClose()

main()
