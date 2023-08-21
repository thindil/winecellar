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

proc main() =

  const
    dtime: float = 20.0
    wineIntervals: array[3, string] = ["daily", "weekly", "monthly"]

  type
    ProgramState = enum
      mainMenu, newApp, newAppWine, newAppDownload, appExec, updateApp, appSettings

    ApplicationData = object
      name, installer, directory, executable: string

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
    wineRefresh: int = 1
    wineLastCheck = now() - 2.years
  # Create the program's configuration directory
  if not dirExists(configDir):
    createDir(configDir & "/apps")
  # Or get the list of installed apps and the program's configuration
  else:
    let programConfig = loadConfig(configDir & "winecellar.cfg")
    wineRefresh = wineIntervals.find(programConfig.getSectionValue("Wine",
        "interval"))
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

  # Initialize the main window of the program
  nuklearInit(800, 600, "Wine Cellar")

  var
    showAbout, initialized, hidePopup, showAppsUpdate, showAppsDelete,
      confirmDelete: bool = false
    state = mainMenu
    appData: ApplicationData
    wineVersion: int = 0
    wineVersions: seq[string]
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
    let prefixDir = expandTilde(appData.directory)
    putEnv("WINEPREFIX", prefixDir)
    discard execCmd(getWineExec(wineVersions[wineVersion], versionInfo[^1]) &
        " " & installerName)
    state = appExec

  proc showAppEdit() =
    setLayoutRowDynamic(0, 2)
    label("Application name:")
    editString(appData.name, 256)
    case state
    of newApp:
      label("Windows installer:")
      editString(appData.installer, 1_024)
      label("Destination directory:")
    of updateApp:
      label("Executable path:")
      editString(appData.executable, 1_024)
      label("Wine directory:")
    else:
      discard
    editString(appData.directory, 1_024)
    label("Wine version:")
    wineVersion = comboList(wineVersions, wineVersion, 25, 200, 200)

  proc createFiles() =
    let
      wineExec = getWineExec(wineVersions[wineVersion], versionInfo[^1])
      appName = appData.name
      winePrefix = appData.directory
    # Remove old files if they exist
    if oldAppName.len > 0:
      removeFile(configDir & "/apps/" & oldAppName & ".cfg")
      removeFile(homeDir & "/" & oldAppName & ".sh")
      if oldAppDir != winePrefix:
        moveDir(oldAppDir, winePrefix)
      oldAppName = ""
      oldAppDir = ""
    let executable = expandTilde(appData.executable)
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
    setLayoutRowDynamic(25, 1)
    for app in installedApps:
      labelButton(app):
        oldAppName = app
        appData.name = app
        let appConfig = loadConfig(configDir & "/apps/" & app & ".cfg")
        appData.executable = appConfig.getSectionValue("General", "exec")
        oldAppDir = appConfig.getSectionValue("General", "prefix")
        appData.directory = oldAppDir
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
        closePopup()
    labelButton("Close"):
      if updating:
        showAppsUpdate = false
      else:
        showAppsDelete = false
      closePopup()

  while true:
    let started = cpuTime()
    # Input
    if nuklearInput():
      break

    # GUI
    window("Main", 0, 0, 800, 600, {windowNoScrollbar}):
      case state
      # The main menu
      of mainMenu:
        setLayoutRowDynamic(0, 1)
        labelButton("Install a new application"):
          state = newApp
        labelButton("Update an existing application"):
          if installedApps.len == 0:
            message = "No applications installed"
          else:
            showAppsUpdate = true
        labelButton("Remove an existing application"):
          if installedApps.len == 0:
            message = "No applications installed"
          else:
            showAppsDelete = true
        labelButton("The program settings"):
          state = appSettings
        labelButton("About the program"):
          showAbout = true
        labelButton("Quit"):
          break
        # The about program popup
        if showAbout:
          popup(staticPopup, "About the program", {windowNoScrollbar}, 275,
              225, 255, 150):
            setLayoutRowDynamic(25, 1)
            label("Simple program for managing Windows apps.")
            label("Version: 0.1", centered)
            label("(c) 2023 Bartek thindil Jasicki", centered)
            label("Released under BSD-3 license", centered)
            labelButton("Close"):
              showAbout = false
              closePopup()
        # Show the list of installed applications to update
        if showAppsUpdate:
          popup(staticPopup, "Update installed application", {
              windowNoScrollbar}, 275, 225, 255, ((installedApps.len + 1) * 32).float):
            showInstalledApps()
        # Show the list of installed applications to delete
        elif showAppsDelete:
          popup(staticPopup, "Delete installed applicaion", {
              windowNoScrollbar}, 275, 225, 255, ((installedApps.len + 1) * 32).float):
            showInstalledApps(false)
        # Show confirmation dialog for delete an installed app
        elif confirmDelete:
          popup(staticPopup, "Delete installed application", {
              windowNoScrollbar}, 275, 225, 255, 75):
            setLayoutRowDynamic(25, 1)
            label(("Are you sure to delete application '" & appData.name & "'?"))
            setLayoutRowDynamic(25, 2)
            labelButton("Yes"):
              removeDir(appData.directory)
              removeFile(homeDir & "/" & appData.name & ".sh")
              removeFile(configDir & "/apps/" & appData.name & ".cfg")
              confirmDelete = false
              message = "The application deleted."
            labelButton("No"):
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
            wineVersions = getWineVersions()
            # Set the default values for a new Windows app
            appData.name = "newApp"
            appData.directory = homeDir & "/newApp"
            initialized = true
      # Installing a new Windows application and Wine if needed
      of newApp, newAppWine, newAppDownload:
        showAppEdit()
        var installerName = expandTilde(appData.installer)
        if state == newApp:
          labelButton("Create"):
            # Check if all fields filled
            if 0 in {appData.name.len, appData.installer.len,
                appData.directory.len}:
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
          labelButton("Cancel"):
            state = mainMenu
        # Download the installer if needed, after installing Wine
        if state == newAppWine and installerName.startsWith("http") and
            not secondThread.running:
          downloadInstaller(installerName)
        # Install the application after downloading Wine or installer
        if state in {newAppWine, newAppDownload} and not secondThread.running:
          if state == newAppWine:
            installerName = expandTilde(appData.installer)
          else:
            installerName = cacheDir & "/" & installerName.split('/')[^1]
          installApp(installerName)
      # Setting a Windows application's executable
      of appExec:
        setLayoutRowDynamic(0, 2)
        label("Executable path:")
        editString(appData.executable, 1_024)
        labelButton("Set"):
          if appData.executable.len == 0:
            message = "You have to enter the path to the executable file."
          if message.len == 0:
            let executable = expandTilde(appData.directory & "/drive_c/" &
                appData.executable)
            if not fileExists(executable):
              message = "The selected file doesn't exist."
            else:
              createFiles()
              message = "The application installed."
        labelButton("Cancel"):
          state = mainMenu
      # Update an installed application
      of updateApp:
        showAppEdit()
        labelButton("Update"):
          # Check if all fields filled
          if 0 in {appData.name.len, appData.directory.len,
              appData.executable.len}:
            message = "You have to fill all the fields."
          if message.len == 0:
            let execName = expandTilde(oldAppDir & "/drive_c/" &
                appData.executable)
            # If the user entered a path to file, check if exists
            if not fileExists(execName):
              message = "The selected executable doesn't exist."
            if message.len == 0:
              createFiles()
              message = "The application updated."
        labelButton("Cancel"):
          state = mainMenu
      # The program's settings
      of appSettings:
        setLayoutRowDynamic(0, 2)
        label("Wine list check:")
        wineRefresh = comboList(wineIntervals, wineRefresh, 25, 200, 200)
        labelButton("Save"):
          state = mainMenu
        labelButton("Cancel"):
          wineRefresh = oldWineRefresh
          state = mainMenu
      # The message popup
      if message.len > 0 or hidePopup:
        popup(staticPopup, "Info", {windowNoScrollbar}, 275, 225,
            getTextWidth(message) + 10.0, 80):
          setLayoutRowDynamic(25, 1)
          label(message)
          labelButton("Close"):
            hidePopup = true
          if hidePopup:
            message = ""
            hidePopup = false
            closePopup()

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
