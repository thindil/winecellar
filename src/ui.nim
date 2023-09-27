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

## The code related to the program's user interface

import std/[httpclient, os, net, parsecfg, strutils, times]
import contracts
import nuklear/nuklear_xlib
import apps, utils, wine

proc showAppEdit*(appData: var ApplicationData; state: ProgramState;
    wineVersion: var int; wineVersions: seq[string]) {.raises: [], tags: [],
    contractual.} =
  ## Show the form to edit the selected application
  ##
  ## * appData      - the information about the Wine's application which will
  ##                  be edited
  ## * state        - the current state of the programs
  ## * wineVersion  - the Wine version selected by the user from the list
  ## * wineVersions - the list of available Wine versions
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

proc showInstalledApps*(installedApps, wineVersions: seq[string]; oldAppName,
    oldAppDir, message: var string; appData: var ApplicationData;
    wineVersion: var int; state: var ProgramState; showAppsUpdate,
    showAppsDelete, confirmDelete: var bool; updating: bool = true) {.raises: [],
    tags: [WriteIOEffect, ReadIOEffect, RootEffect], contractual.} =
  ## Show the list of installed Windows applications managed by the program.
  ##
  ## * installedApps  - the list of installed Wine applications, managed by the
  ##                    program
  ## * wineVersions   - the list of available Wine versions
  ## * oldAppName     - the previous name of the selected Wine application
  ## * oldAppDir      - the previous directory of the selected Wine application
  ## * message        - the message shown to the user
  ## * appData        - the information about the Wine's application which will
  ##                    be updated or deleted
  ## * wineVersion    - the selected Wine version
  ## * state          - the current state of the program
  ## * showAppsUpdate - sets to false, after selecting a Wine application to update
  ## * showAppsDelete - sets to false, after selecting a Wine application to delete
  ## * confirmDelete  - sets to true if user selected a Wine application to delete
  ## * updating       - if true, show the list for update an application action.
  ##                    Otherwise, show the list for delete an application action
  body:
    setLayoutRowDynamic(height = 25, cols = 1)
    for app in installedApps:
      labelButton(title = app):
        oldAppName = app
        appData.name = app
        try:
          let appConfig: Config = loadConfig(filename = configDir &
              "/apps/" & app & ".cfg")
          appData.executable = appConfig.getSectionValue(
              section = "General", key = "exec")
          oldAppDir = appConfig.getSectionValue(section = "General",
              key = "prefix")
          appData.directory = oldAppDir
          var wineExec: string = appConfig.getSectionValue(
              section = "General", key = "wine")
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

proc showMainMenu*(installedApps, versionInfo: seq[string];
    wineVersions: var seq[string]; oldAppName, oldAppDir, message: var string;
    appData: var ApplicationData; wineVersion: var int; state: var ProgramState;
    showAppsUpdate, showAppsDelete, confirmDelete, showAbout, initialized,
    hidePopup: var bool; secondThread: var Thread[ThreadData];
    wineLastCheck: var DateTime): bool {.raises: [NuklearException], tags: [
    WriteIOEffect, WriteDirEffect, ReadDirEffect, ReadEnvEffect, TimeEffect,
    ExecIOEffect, ReadIOEffect, RootEffect], contractual.} =
  ## Show the main program's menu
  ##
  ## * installedApps  - the list of installed Wine applications, managed by the
  ##                    program
  ## * versionInfo    - the information about the FreeBSD version
  ## * wineVersions   - the list of available Wine versions
  ## * oldAppName     - the previous name of the selected Wine application
  ## * oldAppDir      - the previous directory of the selected Wine application
  ## * message        - the message shown to the user
  ## * appData        - the information about the Wine's application which will
  ##                    be updated or deleted
  ## * wineVersion    - the selected Wine version
  ## * state          - the current state of the program
  ## * showAppsUpdate - sets to false, after selecting a Wine application to update
  ## * showAppsDelete - sets to false, after selecting a Wine application to delete
  ## * confirmDelete  - sets to true if user selected a Wine application to delete
  ## * showAbout      - if true, show the dialog about the program
  ## * initialized    - if true, the program is initialized, Wine versions checked.
  ## * hidePopup      - if true, hide currently visible popup window
  ## * secondThread   - the secondary thread on which the check for Wine versions
  ##                    will be done
  ## * wineLastCheck  - the date when the program last checked for available Wine
  ##                    versions
  body:
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
      return true
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
        showInstalledApps(installedApps = installedApps,
            wineVersions = wineVersions, oldAppName = oldAppName,
            oldAppDir = oldAppDir, message = message, appData = appData,
            wineVersion = wineVersion, state = state,
            showAppsUpdate = showAppsUpdate,
            showAppsDelete = showAppsDelete, confirmDelete = confirmDelete)
    # Show the list of installed applications to delete
    elif showAppsDelete:
      popup(pType = staticPopup, title = "Delete installed applicaion",
          flags = {windowNoScrollbar}, x = 275, y = 225, w = 255, h = ((
          installedApps.len + 1) * 32).float):
        showInstalledApps(installedApps = installedApps,
            wineVersions = wineVersions, oldAppName = oldAppName,
            oldAppDir = oldAppDir, message = message, appData = appData,
            wineVersion = wineVersion, state = state,
            showAppsUpdate = showAppsUpdate,
            showAppsDelete = showAppsDelete, confirmDelete = confirmDelete,
            updating = false)
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

proc showInstallNewApp*(appData: var ApplicationData; state: var ProgramState;
    wineVersions, versionInfo: seq[string]; wineVersion: var int;
    message: var string; secondThread: var Thread[ThreadData]) {.raises: [],
    tags: [ReadIOEffect, ReadDirEffect, WriteIOEffect, WriteEnvEffect,
    TimeEffect, ExecIOEffect, RootEffect], contractual.} =
  ## Show the UI for installing a new Windows application and install it
  ##
  ## * appData        - the information about the Wine's application which will
  ##                    be installed
  ## * state          - the current state of the program
  ## * wineVersions   - the list of available Wine versions
  ## * versionInfo    - the information about the FreeBSD version
  ## * wineVersion    - the selected Wine version
  ## * message        - the message shown to the user
  ## * secondThread   - the secondary thread on which the download of the application's
  ##                    data will be done
  body:
    showAppEdit(appData = appData, state = state,
        wineVersion = wineVersion, wineVersions = wineVersions)
    var installerName: string = expandTilde(path = appData.installer)
    if state == newApp:
      labelButton(title = "Create"):
        # Check if all fields filled
        if appData.name.len == 0 or appData.installer.len == 0 or
            appData.directory.len == 0:
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
