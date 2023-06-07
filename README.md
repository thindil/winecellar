### General information

Wine Cellar is, or better will be, a graphical user interface for managing
(installing, setting and removing) Windows programs on FreeBSD. It is loosely
based on Linux program [Bottles](https://usebottles.com/). At this moment,
the whole project is under organization, here is not too much to show.

If you read this file on GitHub: **please don't send pull requests here**. All will
be automatically closed. Any code propositions should go to the
[Fossil](https://www.laeran.pl/repositories/winecellar) repository.

**IMPORTANT:** If you read the file in the project code repository: This
version of the file is related to the future version of the program. It may
contain information not present in released versions of the program. For
that information, please refer to the README.md file included into the release.

#### Build from the source

You will need:

* [Nim compiler](httpVs://nim-lang.org/install.html). You can install it from
  the official repository: `pkg install nim`.
* [Contracts package](https://github.com/Udiknedormin/NimContracts)

You can install them manually or by using [Nimble](https://github.com/nim-lang/nimble).
The program is available in official repository: `pkg install nimble`. If you
installing WineCellar manually, type `nimble install https://github.com/thindil/winecellar`
to install the program and all dependencies. Generally it is recommended to use
`nimble release` to build the project in release (optimized) mode or
`nimble debug` to build it in the debug mode.

### License

The project released under 3-Clause BSD license.

---
That's all for now, more will come over time. ;)

Bartek thindil Jasicki
