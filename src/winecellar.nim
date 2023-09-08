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

import std/[httpclient, os, osproc, net, parsecfg, strutils, times]
import contracts
import nuklear/nuklear_xlib
import wine, utils

proc main() {.raises: [NuklearException], tags: [ExecIOEffect, ReadIOEffect,
    ReadDirEffect, WriteDirEffect, TimeEffect, WriteIOEffect, RootEffect],
    contractual.} =
  body:
    const
      dtime: float = 20.0
      wineIntervals: array[3, string] = ["daily", "weekly", "monthly"]

    type
      ProgramState = enum
        mainMenu, newApp, newAppWine, newAppDownload, appExec, updateApp, appSettings

      ApplicationData = object
        name, installer, directory, executable: string

    # Check the current version of FreeBSD
    var (output, _) = try:
        execCmdEx(command = "uname -rm")
      except OSError, IOError, Exception:
        quit "Can't determine version of FreeBSD."
    output.stripLineEnd
    let versionInfo = output.split(seps = {' ', '-'})
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
      installedApps: seq[string]
      wineRefresh: int = 1
      wineLastCheck = now() - 2.years
    # Create the program's configuration directory
    if not dirExists(dir = configDir):
      try:
        createDir(dir = configDir & "/apps")
      except OSError, IOError:
        quit "Can't create the program's cache directory."
    # Or get the list of installed apps and the program's configuration
    else:
      try:
        let programConfig = loadConfig(filename = configDir & "winecellar.cfg")
        wineRefresh = wineIntervals.find(item = programConfig.getSectionValue(
            section = "Wine", key = "interval"))
        wineLastCheck = programConfig.getSectionValue(section = "Wine",
            key = "lastCheck").parse(f = "yyyy-MM-dd'T'HH:mm:sszzz")
      except ValueError, IOError, OSError, Exception:
        quit "Can't parse the program's configuration."
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
        try:
          removeFile(file = wineJsonFile)
        except OSError, IOError:
          quit "Can't delete the list of Wine versions."
      for file in walkFiles(pattern = configDir & "/apps/" & "*.cfg"):
        var (_, name, _) = file.splitFile
        installedApps.add(y = name)

    # Initialize the main window of the program
    nuklearInit(windowWidth = 800, windowHeight = 600, name = "Wine Cellar")

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

    proc downloadInstaller(installerName: string) {.raises: [], tags: [
        TimeEffect, ReadIOEffect, WriteIOEffect, RootEffect], contractual.} =
      require:
        installerName.len > 0
      body:
        try:
          state = newAppDownload
          message = "Downloading the application's installer."
          createThread(t = secondThread, tp = downloadFile, param = @[
              installerName, cacheDir & "/" & installerName.split(sep = '/')[^1]])
        except HttpRequestError, ValueError, TimeoutError, ProtocolError,
            OSError, IOError, Exception:
          message = "Can't download the program's installer."

    proc installApp(installerName: string) {.raises: [], tags: [ReadIOEffect,
        ReadEnvEffect, WriteEnvEffect, ExecIOEffect, RootEffect],
            contractual.} =
      require:
        installerName.len > 0
      body:
        try:
          let prefixDir = expandTilde(path = appData.directory)
          putEnv(key = "WINEPREFIX", val = prefixDir)
          discard execCmd(command = getWineExec(wineVersion = wineVersions[
              wineVersion], arch = versionInfo[ ^1]) & " " & installerName)
          state = appExec
        except OSError:
          message = "Can't install the application"

    proc showAppEdit() {.raises: [], tags: [], contractual.} =
      body:
        setLayoutRowDynamic(height = 0, cols = 2)
        label(str = "Application name:")
        editString(text = appData.name, maxLen = 256)
        case state
        of newApp:
          label(str = "Windows installer:")
          editString(text = appData.installer, maxLen = 1_024)
          label(str = "Destination directory:")
        of updateApp:
          label(str = "Executable path:")
          editString(text = appData.executable, maxLen = 1_024)
          label(str = "Wine directory:")
        else:
          discard
        editString(text = appData.directory, maxLen = 1_024)
        label(str = "Wine version:")
        wineVersion = comboList(items = wineVersions, selected = wineVersion,
            itemHeight = 25, x = 200, y = 200)

    proc createFiles() {.raises: [], tags: [ReadDirEffect, WriteIOEffect,
        ReadEnvEffect, ReadIOEffect], contractual.} =
      body:
        try:
          let
            wineExec = getWineExec(wineVersion = wineVersions[wineVersion],
                arch = versionInfo[^1])
            appName = appData.name
            winePrefix = appData.directory
          # Remove old files if they exist
          if oldAppName.len > 0:
            removeFile(file = configDir & "/apps/" & oldAppName & ".cfg")
            removeFile(file = homeDir & "/" & oldAppName & ".sh")
            if oldAppDir != winePrefix:
              moveDir(source = oldAppDir, dest = winePrefix)
            oldAppName = ""
            oldAppDir = ""
          let executable = expandTilde(path = appData.executable)
          # Creating the configuration file for the application
          var newAppConfig = newConfig()
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
          message = "Can't create configuration files."

    proc showInstalledApps(updating: bool = true) {.raises: [], tags: [
        WriteIOEffect, ReadIOEffect, RootEffect], contractual.} =
      body:
        setLayoutRowDynamic(height = 25, cols = 1)
        for app in installedApps:
          labelButton(title = app):
            oldAppName = app
            appData.name = app
            try:
              let appConfig = loadConfig(filename = configDir & "/apps/" & app & ".cfg")
              appData.executable = appConfig.getSectionValue(
                  section = "General", key = "exec")
              oldAppDir = appConfig.getSectionValue(section = "General",
                  key = "prefix")
              appData.directory = oldAppDir
              var wineExec = appConfig.getSectionValue(section = "General", key = "wine")
              if wineExec == "wine":
                wineVersion = wineVersions.find(item = "wine").cint
                if wineVersion == -1:
                  wineVersion = wineVersions.find(item = "wine-devel").cint
              elif wineExec.startsWith(prefix = "/usr/local/wine-proton"):
                wineVersion = wineVersions.find(item = "wine-proton").cint
              else:
                wineVersion = wineVersions.find(item = wineExec.split(
                    sep = '/')[^3]).cint
            except IOError, ValueError, OSError, Exception:
              message = "Can't show the selected application."
            if updating:
              state = updateApp
              showAppsUpdate = false
            else:
              showAppsDelete = false
              confirmDelete = true
            closePopup()
        labelButton(title = "Close"):
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
      window(name = "Main", x = 0, y = 0, w = 800, h = 600, flags = {
          windowNoScrollbar}):
        case state
        # The main menu
        of mainMenu:
          setLayoutRowDynamic(height = 0, cols = 1)
          labelButton(title = "Install a new application"):
            state = newApp
          labelButton(title = "Update an existing application"):
            if installedApps.len == 0:
              message = "No applications installed"
            else:
              showAppsUpdate = true
          labelButton(title = "Remove an existing application"):
            if installedApps.len == 0:
              message = "No applications installed"
            else:
              showAppsDelete = true
          labelButton(title = "The program settings"):
            state = appSettings
          labelButton(title = "About the program"):
            showAbout = true
          labelButton(title = "Quit"):
            break
          # The about program popup
          if showAbout:
            popup(pType = staticPopup, title = "About the program", flags = {
                windowNoScrollbar}, x = 275, y = 225, w = 255, h = 150):
              setLayoutRowDynamic(height = 25, cols = 1)
              label(str = "Simple program for managing Windows apps.")
              label(str = "Version: 0.1", alignment = centered)
              label(str = "(c) 2023 Bartek thindil Jasicki",
                  alignment = centered)
              label(str = "Released under BSD-3 license", alignment = centered)
              labelButton(title = "Close"):
                showAbout = false
                closePopup()
          # Show the list of installed applications to update
          if showAppsUpdate:
            popup(pType = staticPopup, title = "Update installed application",
                flags = {windowNoScrollbar}, x = 275, y = 225, w = 255, h = ((
                installedApps.len + 1) * 32).float):
              showInstalledApps()
          # Show the list of installed applications to delete
          elif showAppsDelete:
            popup(pType = staticPopup, title = "Delete installed applicaion",
                flags = {windowNoScrollbar}, x = 275, y = 225, w = 255, h = ((
                installedApps.len + 1) * 32).float):
              showInstalledApps(updating = false)
          # Show confirmation dialog for delete an installed app
          elif confirmDelete:
            popup(pType = staticPopup, title = "Delete installed application",
                flags = {windowNoScrollbar}, x = 275, y = 225, w = 255, h = 75):
              setLayoutRowDynamic(height = 25, cols = 1)
              label(str = "Are you sure to delete application '" &
                  appData.name & "'?")
              setLayoutRowDynamic(height = 25, cols = 2)
              labelButton(title = "Yes"):
                try:
                  removeDir(dir = appData.directory)
                  removeFile(file = homeDir & "/" & appData.name & ".sh")
                  removeFile(file = configDir & "/apps/" & appData.name & ".cfg")
                  confirmDelete = false
                  message = "The application deleted."
                except OSError:
                  message = "Can't delete the application"
              labelButton(title = "No"):
                confirmDelete = false
          # Initialize the program, download needed files and set the list of available Wine versions
          if not initialized:
            if not fileExists(filename = wineJsonFile) and
                not secondThread.running:
              wineLastCheck = now()
              message = "Downloading Wine lists."
              try:
                createThread(t = secondThread, tp = downloadWineList, param = @[
                    versionInfo[0], versionInfo[^1], cacheDir &
                    "winefreesbie32.json", wineJsonFile])
              except HttpRequestError, ProtocolError, IOError, Exception:
                message = getCurrentExceptionMsg()
            if not secondThread.running:
              hidePopup = true
              # Build the list of available Wine versions
              wineVersions = try:
                  getWineVersions()
                except WineError:
                  @[]
              if wineVersions.len == 0:
                message = "Can't get the list of Wine versions."
              # Set the default values for a new Windows app
              appData.name = "newApp"
              appData.directory = homeDir & "/newApp"
              initialized = true
        # Installing a new Windows application and Wine if needed
        of newApp, newAppWine, newAppDownload:
          showAppEdit()
          var installerName = expandTilde(path = appData.installer)
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
                    downloadInstaller(installerName = installerName)
                  # Install the application
                  if state == newApp:
                    installApp(installerName = installerName)
            labelButton(title = "Cancel"):
              state = mainMenu
          # Download the installer if needed, after installing Wine
          if state == newAppWine and installerName.startsWith(
              prefix = "http") and not secondThread.running:
            downloadInstaller(installerName = installerName)
          # Install the application after downloading Wine or installer
          if state in {newAppWine, newAppDownload} and not secondThread.running:
            if state == newAppWine:
              installerName = expandTilde(path = appData.installer)
            else:
              installerName = cacheDir & "/" & installerName.split(sep = '/')[^1]
            installApp(installerName = installerName)
        # Setting a Windows application's executable
        of appExec:
          setLayoutRowDynamic(height = 0, cols = 2)
          label(str = "Executable path:")
          editString(text = appData.executable, maxLen = 1_024)
          labelButton(title = "Set"):
            if appData.executable.len == 0:
              message = "You have to enter the path to the executable file."
            if message.len == 0:
              let executable = expandTilde(path = appData.directory &
                  "/drive_c/" & appData.executable)
              if not fileExists(filename = executable):
                message = "The selected file doesn't exist."
              else:
                createFiles()
                message = "The application installed."
          labelButton(title = "Cancel"):
            state = mainMenu
        # Update an installed application
        of updateApp:
          showAppEdit()
          labelButton(title = "Update"):
            # Check if all fields filled
            if 0 in {appData.name.len, appData.directory.len,
                appData.executable.len}:
              message = "You have to fill all the fields."
            if message.len == 0:
              let execName = expandTilde(path = oldAppDir & "/drive_c/" &
                  appData.executable)
              # If the user entered a path to file, check if exists
              if not fileExists(filename = execName):
                message = "The selected executable doesn't exist."
              if message.len == 0:
                createFiles()
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
              setLayoutRowDynamic(25, 1)
              label(message)
              labelButton("Close"):
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
      let dt = cpuTime() - started
      if (dt < dtime):
        sleep((dtime - dt).int)

    # Creating the configuration file for the application
    var newProgramConfig = newConfig()
    try:
      newProgramConfig.setSectionKey("Wine", "interval", $wineIntervals[wineRefresh])
      newProgramConfig.setSectionKey("Wine", "lastCheck", $wineLastCheck)
      newProgramConfig.writeConfig(configDir & "winecellar.cfg")
    except KeyError, IOError, OSError:
      echo "Can't save the program's configuration."
    nuklearClose()

try:
  main()
except NuklearException:
  quit "Can't create the main window of the program."
