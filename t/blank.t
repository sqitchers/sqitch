#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 33;
#use Test::More 'no_plan';
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use App::Sqitch;
use App::Sqitch::Plan;
use Test::MockModule;
use Test::File;
use Test::File::Contents;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Blank';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    note
    plan
    note_prompt
);

my $sqitch = App::Sqitch->new;
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
isa_ok my $blank = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
), $CLASS;
isa_ok $blank, 'App::Sqitch::Plan::Line';

is $blank->format_name, '', 'Name should format as ""';
is $blank->as_string, '', 'should stringify to ""';

ok $blank = $CLASS->new(
    name    => 'howdy',
    plan    => $plan,
    lspace  => '  ',
    rspace  => "\t",
    note   => 'blah blah blah',
), 'Create tag with more stuff';

is $blank->as_string, "  \t# blah blah blah",
    'It should stringify correctly';

ok $blank = $CLASS->new(plan => $plan, note => "foo\nbar\nbaz\\\n"),
    'Create a blank with newlines and backslashes in the note';
is $blank->note, "foo\nbar\nbaz\\",
    'The newlines and backslashe should not be escaped';

is $blank->format_note, '# foo\\nbar\\nbaz\\\\',
    'The newlines and backslahs should be escaped by format_note';

ok $blank = $CLASS->new(plan => $plan, note => "foo\\nbar\\nbaz\\\\\\n"),
    'Create a blank with escapes';
is $blank->note, "foo\nbar\nbaz\\\n", 'Note shoud be unescaped';

for my $spec (
    ["\n\n\nfoo" => 'foo', 'Leading newlines' ],
    ["\r\r\rfoo" => 'foo', 'Leading line feeds' ],
    ["foo\n\n\n" => 'foo', 'Trailing newlines' ],
    ["foo\r\r\r" => 'foo', 'trailing line feeds' ],
    ["\r\n\r\n\r\nfoo\n\nbar\r" => "foo\n\nbar", 'Leading and trailing vertical space' ],
    ["\n\n\n  foo \n" => '  foo ', 'Laeading and trailing newlines but not spaces' ],
) {
    is $CLASS->new(
        plan    => $plan,
        note   => $spec->[0]
    )->note, $spec->[1], "Should trim $spec->[2] from note";
}

##############################################################################
# Test note requirement.
is $blank->note_prompt,
    __ "Write a note.\nLines starting with '#' will be ignored.",
    'Should have localized not prompt';

my $sqitch_mocker = Test::MockModule->new('App::Sqitch');
my $note = '';
$sqitch_mocker->mock(run => sub {
    my ( $self, $editor, $fn ) = @_;
    is $editor, $sqitch->editor, 'First arg to run() should be editor';
    file_exists_ok $fn, 'Temp file should exist';

    ( my $prompt = $CLASS->note_prompt ) =~ s/^/# /gms;
    file_contents_is $fn, "$/$prompt$/", 'Temp file contents should include prompt';

    if ($note) {
        open my $fh, '>:encoding(UTF-8)', $fn or die "Cannot open $fn: $!";
        print $fh $note, $prompt, $/;
        close $fh or die "Error clsing $fn: $!";
    }

});

throws_ok { $CLASS->new(plan => $plan, require_note => 1 ) } 'App::Sqitch::X',
    'Should get exception for no note text';
is $@->ident, 'plan', 'No note error ident should be "plan"';
is $@->message, __ 'Aborting due to empty note',
    'No note error message should be correct';
is $@->exitval, 1, 'Exit val should be 1';

# Now write a note.
$note = "This is my awesome note.\n";
ok $blank = $CLASS->new(plan => $plan, require_note => 1 ),
    'Add a note via the editor';
is $blank->note, 'This is my awesome note.', 'The note should be set';
