#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 4;
use File::Spec;
use Capture::Tiny qw(:all);

# Requires xt/locale/LocaleData; see xt/locale/README.md for details.
my @cli = (qw(-Ilib -CAS -Ixt/locale), File::Spec->catfile(qw(bin sqitch)));

# Windows has its own locale names for some reason.
# https://stackoverflow.com/q/77771097/79202
my %lang_for = (
    "en_US" => 'English_United States.1252',
    "fr_FR" => 'French_France.1252',
    "de_DE" => 'German_Germany.1252',
    "it_IT" => 'Italian_Italy.1252',
);

# Other supported OSes just use the code name.
if ($^O ne 'MSWin32') {
    $lang_for{$_} = "$_.UTF-8" for keys %lang_for;
}

# Each locale must be installed on the local system. Adding a new lang? Also add
# the relevant language-pack-XX package to os.yml and perl.yml.
for my $tc (
    { lang => 'en_US', err => q{"nonesuch" is not a valid command} },
    { lang => 'fr_FR', err => q{"nonesuch" n'est pas une commande valide} },
    { lang => 'de_DE', err => q{"nonesuch" ist ein ungültiger Befehl} },
    { lang => 'it_IT', err => q{"nonesuch" non è un comando valido} },
) {
    subtest $tc->{lang} || 'default' => sub {
        local $ENV{LC_ALL} = $lang_for{$tc->{lang}};

        # Test successful run.
        my ($stdout, $stderr, $exit) = capture { system $^X, @cli, 'help' };
        is $exit >> 8, 0, 'Should have exited normally';
        like $stdout, qr/\AUsage\b/, 'Should have usage statement in STDOUT';
        is $stderr, '', 'Should have no STDERR';

        # Test localized error.
        ($stdout, $stderr, $exit) = capture { system $^X, @cli, 'nonesuch' };
        is $exit >> 8, 2, 'Should have exit val 2';
        is $stdout, '', 'Should have no STDOUT';
        TODO: {
            # The Windows locales don't translate into the language codes
            # recognized by Locale::TextDomain/gettext. Not at all sure how to
            # fix this. Some relevant notes in the FAQ:
            # https://metacpan.org/dist/libintl-perl/view/lib/Locale/libintlFAQ.pod#How-do-I-switch-languages-or-force-a-certain-language-independently-from-user-settings-read-from-the-environment?
            local $TODO = $^O eq 'MSWin32' ? 'localization fails on Windows' : '';
            like $stderr, qr/\A\Q$tc->{err}/,
                'Should have localized error message in STDERR';
        }
    };
}
