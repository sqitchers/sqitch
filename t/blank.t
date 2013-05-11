#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 34;
#use Test::More 'no_plan';
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use App::Sqitch;
use App::Sqitch::Plan;
use Test::MockModule;
use Test::File;
use Test::File::Contents 0.20;

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
    request_note
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
is $blank->note_prompt(for => 'add'), __x(
    "Write a {command} note.\nLines starting with '#' will be ignored.",
    command => 'add'
), 'Should have localized not prompt';

my $sqitch_mocker = Test::MockModule->new('App::Sqitch');
my $note = '';
my $for  = 'add';
$sqitch_mocker->mock(shell => sub {
    my ( $self, $cmd ) = @_;
    my $editor = $sqitch->editor;
    ok $cmd =~ s/^\Q$editor\E //, 'Shell command should start with editor';
    my $fn = $cmd;
    file_exists_ok $fn, 'Temp file should exist';

    ( my $prompt = $CLASS->note_prompt(for => $for) ) =~ s/^/# /gms;
    file_contents_eq $fn, "\n$prompt\n", 'Temp file contents should include prompt',
        { encoding => ':raw:utf8_strict' };

    if ($note) {
        open my $fh, '>:utf8_strict', $fn or die "Cannot open $fn: $!";
        print $fh $note, $prompt, "\n";
        close $fh or die "Error closing $fn: $!";
    }
});

throws_ok { $CLASS->new(plan => $plan )->request_note(for => $for) }
    'App::Sqitch::X',
    'Should get exception for no note text';
is $@->ident, 'plan', 'No note error ident should be "plan"';
is $@->message, __ 'Aborting due to empty note',
    'No note error message should be correct';
is $@->exitval, 1, 'Exit val should be 1';

# Now write a note.
$for = 'rework';
$note = "This is my awesome note.\n";
$blank = $CLASS->new(plan => $plan );
is $blank->request_note(for => $for), 'This is my awesome note.', 'Request note';
$note = '';
is $blank->note, 'This is my awesome note.', 'Should have the edited note';
is $blank->request_note(for => $for), 'This is my awesome note.',
    'The request should not prompt again';
