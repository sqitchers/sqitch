Releasing Sqitch
================

Notes on the steps to make a release of Sqitch. In the steps, below, examples
use the `$VERSION` environment variable for consistency. The assumption is that
it's set to the new version being released, e.g.,

``` sh
export VERSION=1.2.0
```

Preparation
-----------

First, update the sources so that everything is up-to-date.

*   Install all author dependencies:

    ``` sh
    cpan Dist::Zilla
    dzil authordeps --missing | cpanm
    ```

*   Update the translation dictionaries:

    ``` sh
    dzil msg-scan
    perl -i -pe 's/\QSOME DESCRIPTIVE TITLE./Sqitch Localization Messages/' po/App-Sqitch.pot
    perl -i -pe 's/\Q(C) YEAR/(c) 2012-2021/' po/App-Sqitch.pot
    dzil msg-merge
    git commit -am 'Update translation dictionaries'
    ```

*   Proofread Changes and fix any spelling or grammatical errors, and edit
    descriptions to minimize confusion.

*   Update copyright dates if a year has turned over since the last release:

    ``` sh
    grep -ril copyright . | xargs perl -i -pe 's/-2021/-2022/g'
    ```

*   Make a build and run `xt/dependency_report`:

    ``` sh
    dzil build
    xt/dependency_report App-Sqitch-*/META.json
    ```

    Review the build-time dependency list it outputs to ensure that they are
    well and truly build-time-only. Also, check the runtime list to ensure that
    they are runtime-only. And finally, review the overlapping list to ensure
    that all of the items there are used at runtime. If it all checks out and
    looks reasonable, copy the list of build-time-only dependencies into the
    `__DATA__` section of `inc/Menlo/Sqitch.pm` and commit. This allows the
    `./Build bundle` command to remove any build-only dependencies from the
    bundle.

*   Add any new dependencies to `dist/sqitch.spec` and add a new entry to the
    top of the `%changelog` section for the new version.

*   Update the version in `dist.ini` and `dist/sqitch.spec`, and make sure
    its the same in `Changes`. Timestamp the entry in `Changes`.

*   Merge all the changes into `develop` and makes sure that all of the
    [workflow actions] pass.

Release
-------

The complete set of changes should now be in the `develop` branch and
ready-to-go, fully tested and with no expectation for further changes. It's time
to get it out there!

*   Merge `develop` into the `main` branch:

    ``` sh
    git merge --no-ff -m "Merge develop for v$VERSION" develop
    git push
    ```

*   Once again, ensure all the [workflow actions] pass, and then tag it for
    release:

    ``` sh
    git tag v$VERSION -sm "Tag v$VERSION"
    git push --tags
    ```

*   This will trigger the [Release action]. Ensure it finishes properly, then
    review the [GitHub release] it made, ensuring that the tarball was added to
    the release and that the list of Changes is nicely formatted. It should also
    appear [on CPAN] a short time later.

*   Congratulations, you'e released a new version of Sqitch! Just a few changes
    left to make.

Web Site
--------

To update the web site, clone the [sqitch.org repository] and edit
`.github/workflows/build.yml`, changing the version in the "Check out Sqitch"
step to the new version. Commit and push. Watch the [build action] to be sure
that the new site builds properly, and that the [manual] is rebuilt.

Docker
------

To update the Docker image, first preserve the previous release in a branch,
then make the updates.

*   Create a branch for the previous release so that it can still be supported
    if necessary. For v1.1.0, for example, do this:

    ``` sh
    git checkout -b v1.1.0-maint
    git push origin -u v1.1.0-maint
    ```

*   Switch back to the main branch and update it for the new version:

    ``` sh
    git checkout main
    perl -i -pe "s/^(VERSION)=.+/\$1=$VERSION/" build
    ```

*   Edit the `README.md` to add the new version to the list of tags. It should
    also be listed as using the `latest` tag.

*   Commit and push the changes:

    ``` sh
    git commit -am "Upgrade Sqitch to v$VERSION'
    git push
    ```

*   Watch the [CI/CD action] to make sure the build finishes and publishes the new
    Docker image [on Docker Hub].

*   Test the new version with Docker. This command should should show a usage
    statement for the new version:

    ``` sh
    docker run -it --rm sqitch/sqitch:v$VERSION
    ```

*   Log into Docker Hub and update the description of the [repository page] with
    the new release tag. Find the credentials in the shared 1Password vault.

Homebrew
--------

Update the Sqitch Homebrew tap with the new version.

*   Download the tarball for the new version from CPAN and generate a SHA-256
    for it

    ```
    curl -O https://www.cpan.org/authors/id/D/DW/DWHEELER/App-Sqitch-v$VERSION.tar.gz
    shasum -a 256 App-Sqitch-v$VERSION.tar.gz
    ```

*   Clone the [homebrew-sqitch] repository and edit the `Formula/sqitch.rb` file
    setting the `version` line to the new version and the `sha256` to the value
    from the previous command.

*   Commit, tag, and push.

    ``` sh
    git commit -am "Upgrade to v$VERSION"
    git tag v$VERSION -sm "Tag v$VERSION"
    git push
    git push --tags
    ```

*   And that's all it takes. If you don't already have the tap with Sqitch
    installed, you can tap and install the new version with SQLite support) with
    these commands:

    ``` sh
    brew tap sqitchers/sqitch
    brew install sqitch --with-sqlite-support
    ```

    Or, if you already have it installed:

    ``` sh
    brew update
    brew upgrade
    ```

Finishing Up
------------

Time to get things started for the next version. Switch back to the `develop`
branch, merge `main`, and change the version to a pre-release version. For
example, if you've just released `v1.2.0`, change the version to `v1.2.1-dev`.

``` sh
git checkout develop
git merge main
perl -i -pe 's/^(version\s*=).+/$1 v1.2.1-dev/' dist.ini
perl -i -pe 's{(App/Sqitch version).+}{$1 v1.2.1-dev}' README.md
perl -i -pe 's/(Project-Id-Version: App-Sqitch)[^\\n]+/$1 v1.2.1-dev/' po/App-Sqitch.pot
perl -i -pe 's/(Version:\s*).+/${1}1.2.1-dev/' dist/sqitch.spec
```

Also add a line for the new version (without the pre-release part) to the top of
the `Changes` file. Then commit and push the changes and you're done! Time to
start work on the next release. Good luck!

  [workflow actions]: https://github.com/sqitchers/sqitch/actions
  [Release action]: https://github.com/sqitchers/sqitch/actions/workflows/release.yml
  [GitHub release]: https://github.com/sqitchers/sqitch/releases
  [on CPAN]: https://metacpan.org/dist/App-Sqitch
  [sqitch.org repository]: https://github.com/sqitchers/sqitch.org
  [build action]: https://github.com/sqitchers/sqitch.org/actions/workflows/build.yml
  [manual]: http://sqitch.org/docs/manual/
  [CI/CD action]: https://github.com/sqitchers/docker-sqitch/actions/workflows/cicd.yml
  [on Docker Hub]: https://hub.docker.com/r/sqitch/sqitch
  [repository page]: https://hub.docker.com/repository/docker/sqitch/sqitch
  [homebrew-sqitch]: https://github.com/sqitchers/homebrew-sqitch
