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

import std/[os, osproc, net, parsecfg, strutils, times]
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
      wineRefresh, wineDependencies: int = 1
      wineLastCheck, dependenciesLastCheck: DateTime = now() - 2.years
    # Get the list of installed apps and the program's configuration
    if dirExists(dir = configDir):
      try:
        let programConfig: Config = loadConfig(filename = configDir & "winecellar.cfg")
        wineRefresh = wineIntervals.find(item = programConfig.getSectionValue(
            section = "Wine", key = "interval"))
        wineLastCheck = programConfig.getSectionValue(section = "Wine",
            key = "lastCheck").parse(f = "yyyy-MM-dd'T'HH:mm:sszzz")
        wineDependencies = wineIntervals.find(
            item = programConfig.getSectionValue(section = "Dependencies",
            key = "interval"))
        dependenciesLastCheck = programConfig.getSectionValue(
            section = "Dependencies", key = "lastCheck").parse(
            f = "yyyy-MM-dd'T'HH:mm:sszzz")
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
        confirmDelete, winetricks: bool = false
      state: ProgramState = mainMenu
      appData: ApplicationData = ApplicationData(name: "", installer: "",
          directory: "", executable: "")
      wineVersion: int = 0
      wineVersions: seq[string] = @[]
      message, oldAppName, oldAppDir: string = ""
      oldWineRefresh: int = wineRefresh
    var updateDep: bool = case wineDependencies
      of 0:
        now() - 1.days > dependenciesLastCheck
      of 1:
        now() - 1.weeks > dependenciesLastCheck
      of 2:
        now() - 1.months > dependenciesLastCheck
      else:
        false

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
              secondThread = secondThread, wineLastCheck = wineLastCheck,
              depLastCheck = dependenciesLastCheck, updateDep = updateDep):
            break
        # Installing a new Windows application and Wine if needed
        of newApp, newAppWine, newAppDownload:
          showInstallNewApp(appData = appData, state = state,
              wineVersions = wineVersions, versionInfo = versionInfo,
              wineVersion = wineVersion, message = message,
              secondThread = secondThread, winetricks = winetricks)
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
          showUpdateApp(appData = appData, state = state,
              wineVersions = wineVersions, versionInfo = versionInfo,
              wineVersion = wineVersion, oldAppName = oldAppName,
              oldAppDir = oldAppDir, message = message, winetricks = winetricks)
        # The program's settings
        of appSettings:
          setLayoutRowDynamic(height = 0, cols = 2)
          label(str = "Wine list check:")
          wineRefresh = comboList(items = wineIntervals, selected = wineRefresh,
              itemHeight = 25, x = 200, y = 200)
          label(str = "Wine dependencies check:")
          wineDependencies = comboList(items = wineIntervals,
              selected = wineDependencies, itemHeight = 25, x = 200, y = 200)
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
      newProgramConfig.setSectionKey(section = "Dependencies", key = "interval",
          value = $wineIntervals[wineDependencies])
      newProgramConfig.setSectionKey(section = "Dependencies",
          key = "lastCheck", value = $dependenciesLastCheck)
      newProgramConfig.writeConfig(filename = configDir & "winecellar.cfg")
    except KeyError, IOError, OSError:
      echo "Can't save the program's configuration."
    nuklearClose()

try:
  main()
except NuklearException:
  quit "Can't create the main window of the program."
