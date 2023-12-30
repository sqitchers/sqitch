Sqitch Locale Test
==================

This directory contains the files necessary to test the Sqitch CLI to ensure it
properly detects locale settings and emits translated messages. The
[`po` directory here](./po/), unlike the canonical translations in the root `po`
directory, contains only a few languages translating a single message:

```
"{command}" is not a valid command
```

The `LocaleData` directory contains the compiled forms of these dictionaries,
and unlike the main dictionaries, these are committed to the repository. This
allows the [OS](.github/workflows/os.yml) and [Perl](.github/workflows/os.yml)
workflows to run without the overhead of compiling them (a PITA since `gettext`
is hard to get on Windows and Dist::Zilla supports only more recent versions of
Perl). If the messages need to change, recompile the dictionaries with these
commands:

```sh
cpanm Dist::Zilla --notest
dzil authordeps --missing | cpanm --notest
dzil msg-compile -d xt/locale xt/locale/po/*.po
```

For errors where it can't find `msgformat` or `gettext`, be sure that [gettext]
is installed (readily available via `apt-get`, `yum`, or `brew`).

Now run the test, which validates the output from [`bin/sqitch`](bin/sqitch):

```sh
prove -lv xt/locale/test-cli.t
```

If tests fail, be sure each of the locales is installed on your system.
Apt-based systems, for example, require the relevant language packs:

```sh
sudo apt-get install -qq language-pack-fr language-pack-en language-pack-de language-pack-it
```

  [gettext]: https://www.gnu.org/software/gettext/
