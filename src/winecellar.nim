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

## The main module of the program

import std/[httpclient, os, osproc, net, parsecfg, strutils, times]
import contracts, nimalyzer
import nuklear/nuklear_xlib
import apps, wine, ui, utils

proc main() {.raises: [NuklearException], tags: [ExecIOEffect, ReadIOEffect,
    ReadDirEffect, WriteDirEffect, TimeEffect, WriteIOEffect, RootEffect],
    contractual.} =
  ## The main procedure of the program.
  body:
    const
      dtime: float = 20.0
      wineIntervals: array[3, string] = ["daily", "weekly", "monthly"]

    # Check the current version of FreeBSD
    var (output, _) = try:
        execCmdEx(command = "uname -rm")
      except OSError, IOError, Exception:
        quit "Can't determine version of FreeBSD."
    output.stripLineEnd
    let versionInfo: seq[string] = output.split(seps = {' ', '-'})
    # Create the directory for temporary program's files
    if not fileExists(filename = wineJsonFile):
      try:
        createDir(dir = cacheDir)
      except OSError, IOError:
        quit "Can't create the program's cache directory."
    # Create directories for the program data
    if not dirExists(dir = dataDir):
      try:
        createDir(dir = dataDir & "i386/usr/share/keys")
        createSymlink(src = "/usr/share/keys/pkg", dest = dataDir & "i386/usr/share/keys/pkg")
        if versionInfo[^1] == "amd64":
          createDir(dir = dataDir & "amd64/usr/share/keys")
          createSymlink(src = "/usr/share/keys/pkg", dest = dataDir & "amd64/usr/share/keys/pkg")
      except OSError, IOError:
        quit "Can't create the program's data directory."
    var
      installedApps: seq[string] = @[]
      wineRefresh: int = 1
      wineLastCheck: DateTime = now() - 2.years
    # Get the list of installed apps and the program's configuration
    if dirExists(dir = configDir):
      try:
        let programConfig: Config = loadConfig(filename = configDir & "winecellar.cfg")
        wineRefresh = wineIntervals.find(item = programConfig.getSectionValue(
            section = "Wine", key = "interval"))
        wineLastCheck = programConfig.getSectionValue(section = "Wine",
            key = "lastCheck").parse(f = "yyyy-MM-dd'T'HH:mm:sszzz")
      except ValueError, IOError, OSError, Exception:
        quit "Can't parse the program's configuration."
      let deleteWineList: bool = case wineRefresh
        of 0:
          now() - 1.days > wineLastCheck
        of 1:
          now() - 1.weeks > wineLastCheck
        of 2:
          now() - 1.months > wineLastCheck
        else:
          false
      if deleteWineList:
        try:
          removeFile(file = wineJsonFile)
        except OSError, IOError:
          quit "Can't delete the list of Wine versions."
      for file in walkFiles(pattern = configDir & "/apps/" & "*.cfg"):
        var (_, name, _) = file.splitFile
        installedApps.add(y = name)
    # Or create the program's configuration directory
    else:
      try:
        createDir(dir = configDir & "/apps")
      except OSError, IOError:
        quit "Can't create the program's cache directory."

    # Initialize the main window of the program
    nuklearInit(windowWidth = 800, windowHeight = 600, name = "Wine Cellar")

    {.ruleOff: "varDeclared".}
    var secondThread: Thread[ThreadData]
    {.ruleOn: "varDeclared".}
    var
      showAbout, initialized, hidePopup, showAppsUpdate, showAppsDelete,
        confirmDelete: bool = false
      state: ProgramState = mainMenu
      appData: ApplicationData = ApplicationData(name: "", installer: "",
          directory: "", executable: "")
      wineVersion: int = 0
      wineVersions: seq[string] = @[]
      message, oldAppName, oldAppDir: string = ""
      oldWineRefresh: int = wineRefresh

    while true:
      let started: float = cpuTime()
      # Input
      if nuklearInput():
        break

      # GUI
      window(name = "Main", x = 0, y = 0, w = 800, h = 600, flags = {
          windowNoScrollbar}):
        case state
        # The main menu
        of mainMenu:
          if showMainMenu(installedApps = installedApps,
              versionInfo = versionInfo, wineVersions = wineVersions,
              oldAppName = oldAppName, oldAppDir = oldAppDir, message = message,
              appData = appData, wineVersion = wineVersion, state = state,
              showAppsUpdate = showAppsUpdate, showAppsDelete = showAppsDelete,
              confirmDelete = confirmDelete, showAbout = showAbout,
              initialized = initialized, hidePopup = hidePopup,
              secondThread = secondThread, wineLastCheck = wineLastCheck):
            break
        # Installing a new Windows application and Wine if needed
        of newApp, newAppWine, newAppDownload:
          showAppEdit(appData = appData, state = state,
              wineVersion = wineVersion, wineVersions = wineVersions)
          var installerName: string = expandTilde(path = appData.installer)
          if state == newApp:
            labelButton(title = "Create"):
              # Check if all fields filled
              if 0 in {appData.name.len, appData.installer.len,
                  appData.directory.len}:
                message = "You have to fill all the fields."
              if message.len == 0:
                # If the user entered a path to file, check if exists
                if not installerName.startsWith(prefix = "http"):
                  if not fileExists(filename = installerName):
                    message = "The application installer doesn't exist."
                if message.len == 0:
                  # If Wine version isn't installed, download and install it
                  if $wineVersions[wineVersion] notin systemWine:
                    if not dirExists(dir = dataDir & "i386/usr/local/" &
                        $wineVersions[wineVersion]):
                      message = "Installing the Wine and its dependencies."
                      state = newAppWine
                      try:
                        createThread(t = secondThread, tp = installWine,
                            param = @[$wineVersions[wineVersion], versionInfo[
                            ^1], cacheDir, versionInfo[0], dataDir])
                      except InstallError, HttpRequestError, ValueError,
                          TimeoutError, ProtocolError, OSError, IOError, Exception:
                        message = getCurrentExceptionMsg()
                  # Download the installer if needed
                  if installerName.startsWith(prefix = "http") and state == newApp:
                    downloadInstaller(installerName = installerName,
                        state = state, message = message,
                        secondThread = secondThread)
                  # Install the application
                  if state == newApp:
                    message = installApp(installerName = installerName,
                        appData = appData, wineVersions = wineVersions,
                        versionInfo = versionInfo, wineVersion = wineVersion)
                    if message.len == 0:
                      state = appExec
            labelButton(title = "Cancel"):
              state = mainMenu
          # Download the installer if needed, after installing Wine
          if state == newAppWine and installerName.startsWith(
              prefix = "http") and not secondThread.running:
            downloadInstaller(installerName = installerName, state = state,
                message = message, secondThread = secondThread)
          # Install the application after downloading Wine or installer
          if state in {newAppWine, newAppDownload} and not secondThread.running:
            if state == newAppWine:
              installerName = expandTilde(path = appData.installer)
            else:
              installerName = cacheDir & "/" & installerName.split(sep = '/')[^1]
            message = installApp(installerName = installerName,
                appData = appData, wineVersions = wineVersions,
                versionInfo = versionInfo, wineVersion = wineVersion)
            if message.len == 0:
              state = appExec
        # Setting a Windows application's executable
        of appExec:
          setLayoutRowDynamic(height = 0, cols = 2)
          label(str = "Executable path:")
          editString(text = appData.executable, maxLen = 1_024)
          labelButton(title = "Set"):
            if appData.executable.len == 0:
              message = "You have to enter the path to the executable file."
            if message.len == 0:
              let executable: string = expandTilde(path = appData.directory &
                  "/drive_c/" & appData.executable)
              if fileExists(filename = executable):
                createFiles(wineVersions = wineVersions,
                    versionInfo = versionInfo, wineVersion = wineVersion,
                    appData = appData, oldAppName = oldAppName,
                    oldAppDir = oldAppDir, message = message, state = state)
                if message.len == 0:
                  message = "The application installed."
              else:
                message = "The selected file doesn't exist."
          labelButton(title = "Cancel"):
            state = mainMenu
        # Update an installed application
        of updateApp:
          showAppEdit(appData = appData, state = state,
              wineVersion = wineVersion, wineVersions = wineVersions)
          labelButton(title = "Update"):
            # Check if all fields filled
            if 0 in {appData.name.len, appData.directory.len,
                appData.executable.len}:
              message = "You have to fill all the fields."
            if message.len == 0:
              let execName: string = expandTilde(path = oldAppDir &
                  "/drive_c/" & appData.executable)
              # If the user entered a path to file, check if exists
              if not fileExists(filename = execName):
                message = "The selected executable doesn't exist."
              if message.len == 0:
                createFiles(wineVersions = wineVersions,
                    versionInfo = versionInfo, wineVersion = wineVersion,
                    appData = appData, oldAppName = oldAppName,
                    oldAppDir = oldAppDir, message = message, state = state)
                if message.len == 0:
                  message = "The application updated."
          labelButton(title = "Cancel"):
            state = mainMenu
        # The program's settings
        of appSettings:
          setLayoutRowDynamic(height = 0, cols = 2)
          label(str = "Wine list check:")
          wineRefresh = comboList(items = wineIntervals, selected = wineRefresh,
              itemHeight = 25, x = 200, y = 200)
          labelButton(title = "Save"):
            state = mainMenu
          labelButton(title = "Cancel"):
            wineRefresh = oldWineRefresh
            state = mainMenu
        # The message popup
        if message.len > 0 or hidePopup:
          try:
            popup(pType = staticPopup, title = "Info", flags = {
                windowNoScrollbar}, x = 275, y = 225, w = getTextWidth(
                text = message) + 10.0, h = 80):
              setLayoutRowDynamic(height = 25, cols = 1)
              label(str = message)
              labelButton(title = "Close"):
                hidePopup = true
              if hidePopup:
                message = ""
                hidePopup = false
                closePopup()
          except Exception:
            echo "Can't create a popup"

      # Draw
      nuklearDraw()

      # Timing
      let dt: float = cpuTime() - started
      if (dt < dtime):
        sleep(milsecs = (dtime - dt).int)

    # Creating the configuration file for the application
    var newProgramConfig: Config = newConfig()
    try:
      newProgramConfig.setSectionKey(section = "Wine", key = "interval",
          value = $wineIntervals[wineRefresh])
      newProgramConfig.setSectionKey(section = "Wine", key = "lastCheck",
          value = $wineLastCheck)
      newProgramConfig.writeConfig(filename = configDir & "winecellar.cfg")
    except KeyError, IOError, OSError:
      echo "Can't save the program's configuration."
    nuklearClose()

try:
  main()
except NuklearException:
  quit "Can't create the main window of the program."
