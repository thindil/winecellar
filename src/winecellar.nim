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

const dtime: float = 20.0

proc main() =

  type ProgramState = enum
    mainMenu, newApp

  # Download the list of available wine-freesbie versions
  let
    cacheDir = getEnv("HOME") & "/.cache/winecellar/"
    wineJsonFile = cacheDir & "winefreesbie.json"
  var (output, _) = execCmdEx("uname -rm")
  output.stripLineEnd
  let versionInfo = output.split({' ', '-'})
  if not dirExists(cacheDir):
    createDir(cacheDir)
    let client = newHttpClient(timeout = 5000)
    try:
      writeFile(wineJsonFile, client.getContent(
          "https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
          versionInfo[0] & "-" & versionInfo[2]))
      if versionInfo[2] == "amd64":
        writeFile(cacheDir & "winefreesbie32.json", client.getContent(
            "https://api.github.com/repos/thindil/wine-freesbie/releases/tags/" &
            versionInfo[0] & "-i386"))
    except HttpRequestError:
      discard

  var
    ctx = nuklearInit(800, 600, "Wine Cellar")
    showPopup, showAbout: bool = false
    state = mainMenu
    newAppData: array[3, array[1_024, char]]
    textLen: array[3, cint]
    wineVersion: cint = 0
    wineVersions: seq[cstring] = @[]

  # Build the list of available Wine versions
  # FIXME: Convert seq to array or doen't work (block expression?)
  for wineName in ["wine", "wine-devel", "wine-proton"]:
    if execCmd("pkg info -e " & wineName) == 0:
      wineVersions.add(wineName.cstring)
  let wineJson = parseFile(wineJsonFile)
  for wineAsset in wineJson["assets"]:
    let name = wineAsset["name"].getStr()[0..^5]
    wineVersions.add(name.cstring)

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
          showPopup = true
        if ctx.nk_button_label("Remove an existing application"):
          showPopup = true
        if ctx.nk_button_label("The program settings"):
          showPopup = true
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
        wineVersion = createCombo(ctx, wineVersions, wineVersion, 25, 200, 200)
        if ctx.nk_button_label("Create"):
          showPopup = true
        if ctx.nk_button_label("Cancel"):
          state = mainMenu
      # The message popup
      if showPopup:
        if ctx.createPopup(NK_POPUP_STATIC, "Info", nkWindowNoScrollbar, 275,
            225, 110, 80):
          ctx.nk_layout_row_dynamic(25, 1)
          ctx.nk_label("Not implemeted", NK_TEXT_LEFT)
          if ctx.nk_button_label("Close"):
            showPopup = false
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
