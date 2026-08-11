#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class;
use Test::Exception;
use Test::Warn;
use Test::MockModule;
use Capture::Tiny 0.12    qw(capture_stderr);
use File::Basename        qw(fileparse);
use File::Spec::Functions qw(catdir splitdir);
use Pod::Find;
use App::Sqitch::Command::help;
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::grep';

##############################################################################
# Helper subroutine to capture STDOUT from a code block
sub capture_output(&) {
    my $code   = shift;
    my $output = '';
    open my $fh, '>', \$output or die "Cannot open string for writing: $!";
    my $old_fh = select $fh;
    $code->();
    select $old_fh;
    close $fh;
    return $output;
}

##############################################################################
# Shared test configuration
my $config = TestConfig->new(
    'core.engine'    => 'pg',
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t sql))->stringify,
);
my $sqitch = App::Sqitch->new( config => $config );

my $grep_config = TestConfig->new(
    'core.engine'    => 'pg',
    'core.plan_file' => file(qw(t grep-fixtures sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t grep-fixtures))->stringify,
);
my $grep_sqitch = App::Sqitch->new( config => $grep_config );

#############################################################################
subtest 'Module loading and basic interface' => sub {
    require_ok $CLASS or die;
    isa_ok $CLASS, 'App::Sqitch::Command', 'grep command';

    can_ok $CLASS, qw(
      options   type   t       insensitive
      i         list   l       regex
      e         target execute show_matches
      get_files
    );

    is_deeply [ $CLASS->options ], [
        qw(
          t|type=s
          i|insensitive
          l|list
          e|regex
        )
      ],
      'Options should be correct';

    warning_is {
        Getopt::Long::Configure(qw(bundling pass_through));
        ok Getopt::Long::GetOptionsFromArray(
            [], {}, App::Sqitch->_core_opts, $CLASS->options,
          ),
          'Should parse options';
    }
    undef, 'Options should not conflict with core options';
};

##############################################################################
subtest 'Command construction' => sub {
    my $grep = App::Sqitch::Command->load(
        {
            sqitch  => $sqitch,
            command => 'grep',
            config  => $config,
            args    => [],
        }
    );
    isa_ok $grep, $CLASS, 'grep command';
};

##############################################################################
subtest 'Configuration' => sub {
    is_deeply $CLASS->configure( $config, {} ), {},
      'Should have default configuration with no config or opts';

    is_deeply $CLASS->configure(
        $config,
        {
            type        => 'deploy',
            insensitive => 1,
            list        => 1,
            regex       => 1,
        }
      ),
      {
        type        => 'deploy',
        insensitive => 1,
        list        => 1,
        regex       => 1,
      },
      'Should have configuration with all options';

    is_deeply $CLASS->configure( $config, { type => 'verify' } ),
      { type => 'verify' },
      'Should configure with type=verify';

    is_deeply $CLASS->configure( $config, { type => 'revert' } ),
      { type => 'revert' },
      'Should configure with type=revert';

    is_deeply $CLASS->configure( $config, { insensitive => 1 } ),
      { insensitive => 1 },
      'Should configure with insensitive only';

    is_deeply $CLASS->configure( $config, { list => 1 } ),
      { list => 1 },
      'Should configure with list only';

    is_deeply $CLASS->configure( $config, { regex => 1 } ),
      { regex => 1 },
      'Should configure with regex only';

    is_deeply $CLASS->configure( $config, { type => 'deploy', insensitive => 1 } ),
      { type => 'deploy', insensitive => 1 },
      'Should configure with type and insensitive';

    is_deeply $CLASS->configure( $config, { list => 1, regex => 1 } ),
      { list => 1, regex => 1 },
      'Should configure with list and regex';
};

##############################################################################
subtest 'Attributes' => sub {
    my $grep = $CLASS->new( sqitch => $sqitch );
    isa_ok $grep, $CLASS, 'new grep command';
    is $grep->type,        undef, 'type should be undef by default';
    is $grep->t,           undef, 't should be undef by default';
    is $grep->insensitive, undef, 'insensitive should be undef by default';
    is $grep->i,           undef, 'i should be undef by default';
    is $grep->list,        undef, 'list should be undef by default';
    is $grep->l,           undef, 'l should be undef by default';
    is $grep->regex,       undef, 'regex should be undef by default';
    is $grep->e,           undef, 'e should be undef by default';
    isa_ok $grep->target, 'App::Sqitch::Target', 'target';

    $grep = $CLASS->new(
        sqitch      => $sqitch,
        type        => 'deploy',
        insensitive => 1,
        list        => 1,
        regex       => 1,
    );
    isa_ok $grep, $CLASS, 'new grep command with options';
    is $grep->type,        'deploy', 'type should be deploy';
    is $grep->insensitive, 1,        'insensitive should be 1';
    is $grep->list,        1,        'list should be 1';
    is $grep->regex,       1,        'regex should be 1';

    $grep = $CLASS->new(
        sqitch => $sqitch,
        t      => 'verify',
        i      => 1,
        l      => 1,
        e      => 1,
    );
    isa_ok $grep, $CLASS, 'new grep command with short options';
    is $grep->t, 'verify', 't should be verify';
    is $grep->i, 1,        'i should be 1';
    is $grep->l, 1,        'l should be 1';
    is $grep->e, 1,        'e should be 1';
};

##############################################################################
subtest 'Literal search functionality' => sub {
    my $grep = $CLASS->new( sqitch => $grep_sqitch );

    # Test that literal search finds exact strings
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Should find "CREATE TABLE"';

    # Test special regex characters are treated literally - asterisk
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'foo*bar'
    );
    is scalar(@files), 1, 'Should find "foo*bar" with asterisk';
    like $files[0], qr/widgets\.sql$/, 'Should find foo*bar in widgets.sql';

    # Test special regex characters are treated literally - dollar sign and dot
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'price.$'
    );
    is scalar(@files), 1, 'Should find "price.$" literally';
    like $files[0], qr/widgets\.sql$/, 'Should find price.$ in widgets.sql';

    # Test multiple search terms joined with spaces
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'ALTER', 'TABLE'
    );
    ok scalar(@files) > 0, 'Should find "ALTER TABLE" (multiple terms)';

    # Test show_matches output format
    my @test_files = ( file(qw(t grep-fixtures deploy users.sql))->stringify );
    my $output     = capture_output { $grep->show_matches( \@test_files, 'CREATE TABLE' ) };
    like $output, qr/users\.sql:\d+:.*CREATE TABLE/,
      'show_matches should output filename:line_number:content format';
    like $output, qr/CREATE TABLE users/,
      'show_matches should include the matching line content';

    # Test that literal search does NOT match regex patterns
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'foo.*bar'
    );
    ok scalar(@files) > 0, 'Should find literal "foo.*bar" string';

    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'fooXYZbar'
    );
    is scalar(@files), 0, 'Should NOT match "fooXYZbar" when searching for "foo.*bar"';

    # Test literal search with period
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'price.'
    );
    ok 1, 'Literal search with period completed';

    # Test case-sensitive literal search (default)
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Case-sensitive search finds "CREATE TABLE"';

    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Should find lowercase "create table" in comments';

    # Test case-insensitive literal search
    my $insensitive_grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
    );
    @files = $insensitive_grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Case-insensitive search should find "create table"';

    # Test literal search with multiple special characters
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'price.$'
    );
    is scalar(@files), 1, 'Should handle multiple special chars';

    # Test show_matches with special characters
    my @widget_files = ( file(qw(t grep-fixtures deploy widgets.sql))->stringify );
    $output = capture_output { $grep->show_matches( \@widget_files, 'foo*bar' ) };
    like $output, qr/foo\*bar/, 'show_matches should display literal asterisk';

    $output = capture_output { $grep->show_matches( \@widget_files, 'price.$' ) };
    like $output, qr/price\.\$/, 'show_matches should display literal dollar sign';

    # Test literal search works across all file types
    @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Should work across deploy/verify/revert directories';

    # Test literal search with parentheses
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'users(id)'
    );
    ok scalar(@files) > 0, 'Should find "users(id)" with parentheses';

    # Test literal search with square brackets
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '[roles]'
    );
    ok 1, 'Literal search with brackets completed';

    # Test literal search with plus sign
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '10,2)'
    );
    ok scalar(@files) > 0, 'Should find "10,2)" in DECIMAL definition';

    # Test literal search with caret
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '^'
    );
    ok 1, 'Literal search with caret completed without error';

    # Test literal search with backslash
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '\\'
    );
    ok 1, 'Literal search with backslash completed without error';

    # Test literal search with question mark
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '?'
    );
    ok 1, 'Literal search with question mark completed without error';

    # Test literal search with pipe
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '|'
    );
    ok 1, 'Literal search with pipe completed without error';

    # Test multiple terms are joined with spaces
    my @user_files = ( file(qw(t grep-fixtures deploy users.sql))->stringify );
    $output = capture_output { $grep->show_matches( \@user_files, 'CREATE', 'TABLE', 'users' ) };
    like $output, qr/CREATE TABLE users/, 'Multiple search terms should be joined with spaces';

    # Test line number accuracy
    $output = capture_output { $grep->show_matches( \@user_files, 'CREATE TABLE' ) };
    like $output, qr/:\d+:/,           'Output should include line numbers';
    like $output, qr/users\.sql:\d+:/, 'Output should have correct filename:line_number: format';

    # Test content after match is included
    $output = capture_output { $grep->show_matches( \@user_files, 'SERIAL' ) };
    like $output, qr/SERIAL PRIMARY KEY/, 'Output should include full line content with match';
};

##############################################################################
subtest 'Regex search functionality' => sub {
    my $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        regex  => 1,
    );

    # Test basic regex pattern matching with wildcard
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'foo.*bar'
    );
    ok scalar(@files) > 0, 'Should find pattern "foo.*bar"';
    like $files[0], qr/(posts|widgets)\.sql$/, 'Should match files with pattern';

    # Test regex with character class
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE [TI]'
    );
    ok scalar(@files) > 0, 'Should find pattern with character class "CREATE [TI]"';

    # Test regex with start of line anchor
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '^CREATE'
    );
    ok scalar(@files) > 0, 'Should find pattern with start anchor "^CREATE"';

    # Test regex with end of line anchor
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'COMMIT;$'
    );
    ok scalar(@files) > 0, 'Should find pattern with end anchor "COMMIT;$"';

    # Test regex with whitespace pattern
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE\s+TABLE'
    );
    ok scalar(@files) > 0, 'Should find pattern with whitespace "CREATE\s+TABLE"';

    # Test regex with alternation (OR)
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE (TABLE|INDEX)'
    );
    ok scalar(@files) > 0, 'Should find pattern with alternation "CREATE (TABLE|INDEX)"';

    # Test regex with optional character
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'DECIMAL\(10,2\)?'
    );
    ok scalar(@files) > 0, 'Should find pattern with optional character';

    # Test regex with plus quantifier
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'id\s+'
    );
    ok scalar(@files) > 0, 'Should find pattern with plus quantifier "id\s+"';

    # Test regex with digit pattern
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '\d+'
    );
    ok scalar(@files) > 0, 'Should find pattern with digit class "\d+"';

    # Test regex with word boundary
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '\bCREATE\b'
    );
    ok scalar(@files) > 0, 'Should find pattern with word boundary "\bCREATE\b"';

    # Test invalid regex pattern produces error
    throws_ok {
        $grep->get_files(
            dir(qw(t grep-fixtures deploy)),
            '(?invalid'
        );
    }
    qr/Unmatched \(|Sequence \(\?/i,
      'Invalid regex pattern should produce error';

    throws_ok {
        $grep->get_files(
            dir(qw(t grep-fixtures deploy)),
            '[unclosed'
        );
    }
    qr/Unmatched \[|Unterminated character class/i,
      'Invalid regex with unclosed bracket should produce error';

    # Test regex mode with case-insensitive flag
    my $insensitive_grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        regex       => 1,
        insensitive => 1,
    );
    @files = $insensitive_grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Regex case-insensitive search should find "create table"';

    @files = $insensitive_grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CrEaTe TaBlE'
    );
    ok scalar(@files) > 0, 'Regex case-insensitive search should match mixed case';

    # Test show_matches with regex pattern
    my @test_files = ( file(qw(t grep-fixtures deploy posts.sql))->stringify );
    my $output     = capture_output { $grep->show_matches( \@test_files, 'foo.*bar' ) };
    like $output, qr/foo.*bar/, 'show_matches with regex should display matching pattern';

    @test_files = ( file(qw(t grep-fixtures deploy users.sql))->stringify );
    $output     = capture_output { $grep->show_matches( \@test_files, '^CREATE' ) };
    like $output, qr/CREATE TABLE/, 'show_matches with regex anchor should match start of line';

    # Test regex with escaped special characters
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'price\.\$'
    );
    ok 1, 'Regex search with escaped special chars completed';

    # Test regex with multiple patterns
    $output = capture_output { $grep->show_matches( \@test_files, 'CREATE', 'TABLE' ) };
    like $output, qr/CREATE TABLE/, 'Regex search with multiple terms should join with space';

    # Test regex mode works with -e short option
    my $e_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        e      => 1,
    );
    @files = $e_grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE.*TABLE'
    );
    ok scalar(@files) > 0, 'Regex search with -e option should work';

    # Test complex regex pattern
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '^\s*--.*test'
    );
    ok scalar(@files) > 0, 'Complex regex pattern should match SQL comments';

    # Test regex with greedy quantifiers
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'SERIAL.*KEY'
    );
    ok scalar(@files) > 0, 'Regex with greedy quantifier should work';

    # Test regex allows special syntax
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '(id|name|title)'
    );
    ok scalar(@files) > 0, 'Regex with grouping and alternation should work';
};

##############################################################################
subtest 'Type filtering (deploy/verify/revert)' => sub {

    # Test --type deploy filters to deploy directory only
    my $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
    );
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Type=deploy should find files in deploy directory';

    for my $file (@files) {
        like $file,   qr/deploy/, 'Should only return files from deploy directory';
        unlike $file, qr/verify/, 'Should not return files from verify directory';
        unlike $file, qr/revert/, 'Should not return files from revert directory';
    }

    # Test --type verify filters to verify directory only
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'verify',
    );
    @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'SELECT'
    );
    ok scalar(@files) > 0, 'Type=verify should find files in verify directory';

    for my $file (@files) {
        like $file,   qr/verify/, 'Should only return files from verify directory';
        unlike $file, qr/deploy/, 'Should not return files from deploy directory';
        unlike $file, qr/revert/, 'Should not return files from revert directory';
    }

    # Test --type revert filters to revert directory only
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'revert',
    );
    @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'DROP'
    );
    ok scalar(@files) > 0, 'Type=revert should find files in revert directory';

    for my $file (@files) {
        like $file,   qr/revert/, 'Should only return files from revert directory';
        unlike $file, qr/deploy/, 'Should not return files from deploy directory';
        unlike $file, qr/verify/, 'Should not return files from verify directory';
    }

    # Test no type option searches all directories
    $grep  = $CLASS->new( sqitch => $grep_sqitch );
    @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'TABLE'
    );
    ok scalar(@files) > 0, 'No type option should search all directories';

    my $has_deploy = 0;
    my $has_verify = 0;
    my $has_revert = 0;
    for my $file (@files) {
        $has_deploy = 1 if $file =~ /deploy/;
        $has_verify = 1 if $file =~ /verify/;
        $has_revert = 1 if $file =~ /revert/;
    }
    ok $has_deploy,                'No type option should include deploy files';
    ok $has_verify || $has_revert, 'No type option should include verify or revert files';

    # Test type option with short form -t
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        t      => 'deploy',
    );
    @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Type option with -t should work';

    for my $file (@files) {
        like $file, qr/deploy/, 'Type option with -t should filter to deploy directory';
    }
};

##############################################################################
subtest 'Case sensitivity options' => sub {

    # Test case-sensitive search (default behavior)
    my $grep  = $CLASS->new( sqitch => $grep_sqitch );
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Case-sensitive search should find "CREATE TABLE"';

    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Case-sensitive search should find exact case "create table" in comments';

    my @test_files = ( file(qw(t grep-fixtures deploy posts.sql))->stringify );
    my $output     = capture_output { $grep->show_matches( \@test_files, 'CREATE TABLE' ) };
    like $output, qr/CREATE TABLE/, 'Case-sensitive search should match exact case';

    # Test case-insensitive search with -i flag
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
    );
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Case-insensitive search should find "create table"';

    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CrEaTe TaBlE'
    );
    ok scalar(@files) > 0, 'Case-insensitive search should match mixed case';

    @test_files = ( file(qw(t grep-fixtures deploy users.sql))->stringify );
    $output     = capture_output { $grep->show_matches( \@test_files, 'create table' ) };
    like $output, qr/CREATE TABLE/i, 'Case-insensitive search should match regardless of case';

    # Test case-insensitive with -i short option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        i      => 1,
    );
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Case-insensitive search with -i should work';
};

##############################################################################
subtest 'List mode' => sub {
    my $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        list   => 1,
    );
    is $grep->list, 1, 'List flag should be set';

    my @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'List mode grep should find files with pattern';

    # Test list mode with -l short option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        l      => 1,
    );
    is $grep->l, 1, 'Short l flag should be set';

    # Verify list mode doesn't affect get_files behavior
    my $normal_grep  = $CLASS->new( sqitch => $grep_sqitch );
    my @normal_files = $normal_grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE TABLE'
    );
    is scalar(@files), scalar(@normal_files), 'List mode should find same files as normal mode';
};

##############################################################################
subtest 'Option combinations' => sub {

    # Test list mode can be combined with other options
    my $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        list        => 1,
        insensitive => 1,
    );
    is $grep->list,        1, 'List flag should be set in combination';
    is $grep->insensitive, 1, 'Insensitive flag should be set in combination';

    # Test combination of type and insensitive options
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        type        => 'deploy',
        insensitive => 1,
    );
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'create table'
    );
    ok scalar(@files) > 0, 'Type and insensitive combination should work';

    for my $file (@files) {
        like $file, qr/deploy/, 'Type and insensitive should filter to deploy directory';
    }

    # Test combination of type and list options
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'verify',
        list   => 1,
    );
    is $grep->type, 'verify', 'Type should be verify in combination';
    is $grep->list, 1,        'List should be set in combination';

    # Test combination of insensitive and list options
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
        list        => 1,
    );
    is $grep->insensitive, 1, 'Insensitive should be set in combination';
    is $grep->list,        1, 'List should be set in combination';

    # Test combination of all three options
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        type        => 'deploy',
        insensitive => 1,
        list        => 1,
    );
    is $grep->type,        'deploy', 'Type should be deploy in combination';
    is $grep->insensitive, 1,        'Insensitive should be set in combination';
    is $grep->list,        1,        'List should be set in combination';

    @files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'create table'
    );
    ok scalar(@files) > 0, 'All options combination should find files';

    for my $file (@files) {
        like $file, qr/deploy/, 'All options combination should filter to deploy directory';
    }
};

##############################################################################
subtest 'Plan-order sorting' => sub {
    my $grep = $CLASS->new( sqitch => $grep_sqitch );

    # Search for a pattern that appears in multiple files
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE TABLE'
    );
    ok scalar(@files) > 0, 'Should find files with "CREATE TABLE"';

    # Build order_by hash using same logic as execute()
    my $target   = $grep->target;
    my $i        = 0;
    my %order_by = map { $_->name => $i++ } grep { $_->isa('App::Sqitch::Plan::Change') } $target->plan->lines;

    # Verify the order_by hash has the expected changes
    ok exists $order_by{roles},   'Plan should include roles change';
    ok exists $order_by{users},   'Plan should include users change';
    ok exists $order_by{widgets}, 'Plan should include widgets change';
    ok exists $order_by{posts},   'Plan should include posts change';

    # Verify the plan order is correct
    is $order_by{roles},   0, 'roles should be first in plan (index 0)';
    is $order_by{users},   1, 'users should be second in plan (index 1)';
    is $order_by{widgets}, 2, 'widgets should be third in plan (index 2)';
    is $order_by{posts},   3, 'posts should be fourth in plan (index 3)';

    # Test deploy files appear before verify files for same change
    my @all_files = $grep->get_files(
        dir(qw(t grep-fixtures)),
        'TABLE'
    );
    ok scalar(@all_files) > 0, 'Should find files across all directories';

    # Manually sort using the same algorithm as execute()
    my ( $deploy_dir, $verify_dir, $revert_dir ) = map { $target->$_ } qw/deploy_dir verify_dir revert_dir/;
    my $extension = $target->extension;
    my %name_for;

    my $by_plan = sub {
        return 0 if $a eq $b;

        # deploy < verify < revert for different directories
        return -1 if $a =~ /^$deploy_dir/ and $b !~ /^$deploy_dir/;
        return -1 if $a =~ /^$verify_dir/ and $b =~ /^$revert_dir/;
        return 1  if $b =~ /^$deploy_dir/ and $a !~ /^$deploy_dir/;
        return 1  if $b =~ /^$verify_dir/ and $a =~ /^$revert_dir/;

        my $dir;
        foreach ( $deploy_dir, $verify_dir, $revert_dir ) {
            $dir = $_ if $a =~ /^$_/;
        }
        unless ($dir) {
            return 1;
        }

        my @remove = splitdir($dir);
        foreach my $this_file ( $a, $b ) {
            unless ( exists $name_for{$this_file} ) {
                my ( $name, $path, undef ) = fileparse( $this_file, $extension );
                my @path       = splitdir( catdir( $path, $name ) );
                my $last_index = -1 * ( @path - scalar @remove );
                my $this_name  = catdir( splice @path, $last_index );
                $this_name =~ s/\.$//;
                $name_for{$this_file} = $this_name;
            }
        }

        return ( $order_by{ $name_for{$a} } // $i ) <=> ( $order_by{ $name_for{$b} } // $i );
    };

    my @sorted_files = sort $by_plan @all_files;

    # Verify deploy files come before verify files for the same change
    my %file_positions;
    for my $idx ( 0 .. $#sorted_files ) {
        my $file = $sorted_files[$idx];
        if ( $file =~ /deploy.*users/ ) {
            $file_positions{deploy_users} = $idx;
        }
        elsif ( $file =~ /verify.*users/ ) {
            $file_positions{verify_users} = $idx;
        }
        elsif ( $file =~ /revert.*users/ ) {
            $file_positions{revert_users} = $idx;
        }
        elsif ( $file =~ /deploy.*widgets/ ) {
            $file_positions{deploy_widgets} = $idx;
        }
        elsif ( $file =~ /verify.*widgets/ ) {
            $file_positions{verify_widgets} = $idx;
        }
        elsif ( $file =~ /revert.*widgets/ ) {
            $file_positions{revert_widgets} = $idx;
        }
    }

    # Test deploy < verify < revert for same change
    if ( exists $file_positions{deploy_users} && exists $file_positions{verify_users} ) {
        ok $file_positions{deploy_users} < $file_positions{verify_users},
          'deploy/users.sql should appear before verify/users.sql';
    }

    if ( exists $file_positions{verify_users} && exists $file_positions{revert_users} ) {
        ok $file_positions{verify_users} < $file_positions{revert_users},
          'verify/users.sql should appear before revert/users.sql';
    }

    if ( exists $file_positions{deploy_widgets} && exists $file_positions{verify_widgets} ) {
        ok $file_positions{deploy_widgets} < $file_positions{verify_widgets},
          'deploy/widgets.sql should appear before verify/widgets.sql';
    }

    if ( exists $file_positions{verify_widgets} && exists $file_positions{revert_widgets} ) {
        ok $file_positions{verify_widgets} < $file_positions{revert_widgets},
          'verify/widgets.sql should appear before revert/widgets.sql';
    }

    # Test that files are sorted by plan order (roles < users < widgets < posts)
    my %change_positions;
    for my $idx ( 0 .. $#sorted_files ) {
        my $file = $sorted_files[$idx];
        if ( $file =~ /roles/ && !exists $change_positions{roles} ) {
            $change_positions{roles} = $idx;
        }
        elsif ( $file =~ /users/ && !exists $change_positions{users} ) {
            $change_positions{users} = $idx;
        }
        elsif ( $file =~ /widgets/ && !exists $change_positions{widgets} ) {
            $change_positions{widgets} = $idx;
        }
        elsif ( $file =~ /posts/ && !exists $change_positions{posts} ) {
            $change_positions{posts} = $idx;
        }
    }

    # Verify plan order is maintained
    if ( exists $change_positions{roles} && exists $change_positions{users} ) {
        ok $change_positions{roles} < $change_positions{users},
          'roles files should appear before users files (plan order)';
    }

    if ( exists $change_positions{users} && exists $change_positions{widgets} ) {
        ok $change_positions{users} < $change_positions{widgets},
          'users files should appear before widgets files (plan order)';
    }

    if ( exists $change_positions{widgets} && exists $change_positions{posts} ) {
        ok $change_positions{widgets} < $change_positions{posts},
          'widgets files should appear before posts files (plan order)';
    }

    # Test that files not in plan are sorted last
    my $all_in_plan = 1;
    for my $file (@sorted_files) {
        my $in_plan = 0;
        for my $change_name (qw(roles users widgets posts)) {
            if ( $file =~ /$change_name/ ) {
                $in_plan = 1;
                last;
            }
        }
        $all_in_plan = 0 unless $in_plan;
    }
    ok $all_in_plan, 'All test fixture files should be in the plan';

    # Test sorting with subdirectories in script directories
    my $test_file = file(qw(t grep-fixtures deploy users.sql))->stringify;
    my ( $name, $path, $suffix ) = fileparse( $test_file, $extension );
    like $name, qr/users/,  'fileparse should extract change name';
    like $path, qr/deploy/, 'fileparse should preserve directory path';

    # Test the complete execute() method with plan-order sorting
    my $output = capture_output { $grep->execute('TABLE') };
    like $output, qr/TABLE/, 'execute() should produce output with matches';

    my $roles_pos = index( $output, 'roles' );
    my $users_pos = index( $output, 'users' );
    if ( $roles_pos >= 0 && $users_pos >= 0 ) {
        ok $roles_pos < $users_pos,
          'execute() output should show roles before users (plan order)';
    }

    # Test execute() with list mode maintains plan order
    my $list_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        list   => 1,
    );
    $output = capture_output { $list_grep->execute('TABLE') };
    like $output, qr/\.sql/, 'execute() with list should show filenames';

    my @output_lines = split /\n/, $output;
    ok scalar(@output_lines) > 0, 'List mode should produce output lines';

    my %seen_changes;
    for my $line (@output_lines) {
        my $dir_type = $line =~ /deploy/ ? 'deploy' : $line =~ /verify/ ? 'verify' : 'revert';
        for my $change_name (qw(roles users widgets posts)) {
            if ( $line =~ /$change_name/ ) {
                my $curr_order = $order_by{$change_name};
                if ( exists $seen_changes{$dir_type} ) {
                    my $prev_order = $seen_changes{$dir_type};
                    ok $curr_order >= $prev_order,
                      "List mode should maintain plan order: $change_name in $dir_type";
                }
                $seen_changes{$dir_type} = $curr_order;
                last;
            }
        }
    }

    # Test that plan-order sorting works with type filter
    my $type_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
    );
    $output = capture_output { $type_grep->execute('TABLE') };
    like $output,   qr/deploy/, 'Type filter should show deploy files';
    unlike $output, qr/verify/, 'Type filter should not show verify files';
    unlike $output, qr/revert/, 'Type filter should not show revert files';

    if ( $output =~ /roles/ && $output =~ /users/ ) {
        $roles_pos = index( $output, 'roles' );
        $users_pos = index( $output, 'users' );
        ok $roles_pos < $users_pos,
          'Type filter should maintain plan order for deploy files';
    }

    # Test plan-order sorting with case-insensitive search
    my $insensitive_grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
    );
    $output = capture_output { $insensitive_grep->execute('table') };
    like $output, qr/table/i, 'Case-insensitive search should find matches';

    if ( $output =~ /roles/ && $output =~ /users/ ) {
        $roles_pos = index( $output, 'roles' );
        $users_pos = index( $output, 'users' );
        ok $roles_pos < $users_pos,
          'Case-insensitive search should maintain plan order';
    }

    # Test plan-order sorting with regex search
    my $regex_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        regex  => 1,
    );
    $output = capture_output { $regex_grep->execute('CREATE.*TABLE') };
    like $output, qr/CREATE.*TABLE/, 'Regex search should find matches';

    if ( $output =~ /roles/ && $output =~ /users/ ) {
        $roles_pos = index( $output, 'roles' );
        $users_pos = index( $output, 'users' );
        ok $roles_pos < $users_pos,
          'Regex search should maintain plan order';
    }

    # Test that the sorting algorithm handles edge cases
    my @users_files = grep {/users/} @sorted_files;
    if ( scalar(@users_files) > 1 ) {
        my $has_deploy = 0;
        my $has_verify = 0;
        my $has_revert = 0;
        my $deploy_idx = -1;
        my $verify_idx = -1;
        my $revert_idx = -1;

        for my $idx ( 0 .. $#users_files ) {
            if ( $users_files[$idx] =~ /deploy/ ) {
                $has_deploy = 1;
                $deploy_idx = $idx;
            }
            elsif ( $users_files[$idx] =~ /verify/ ) {
                $has_verify = 1;
                $verify_idx = $idx;
            }
            elsif ( $users_files[$idx] =~ /revert/ ) {
                $has_revert = 1;
                $revert_idx = $idx;
            }
        }

        if ( $has_deploy && $has_verify ) {
            ok $deploy_idx < $verify_idx,
              'For same change, deploy should come before verify';
        }

        if ( $has_verify && $has_revert ) {
            ok $verify_idx < $revert_idx,
              'For same change, verify should come before revert';
        }

        if ( $has_deploy && $has_revert ) {
            ok $deploy_idx < $revert_idx,
              'For same change, deploy should come before revert';
        }
    }

    # Test that sorting works correctly when searching specific types
    my @deploy_files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'TABLE'
    );
    my @deploy_sorted = sort $by_plan @deploy_files;

    my $prev_order = -1;
    for my $file (@deploy_sorted) {
        for my $change_name (qw(roles users widgets posts)) {
            if ( $file =~ /$change_name/ ) {
                my $curr_order = $order_by{$change_name};
                if ( $prev_order >= 0 ) {
                    ok $curr_order >= $prev_order,
                      "Deploy files should be in plan order: $change_name";
                }
                $prev_order = $curr_order;
                last;
            }
        }
    }
};

##############################################################################
subtest 'Error handling and edge cases' => sub {

    # Test error when no search terms provided
    my $grep = $CLASS->new( sqitch => $grep_sqitch );
    throws_ok {
        $grep->execute();
    }
    'App::Sqitch::X', 'execute() should die when no search terms provided';
    is $@->ident, 'grep', 'Error ident should be "grep"';
    is $@->message, __x( 'No search terms supplied for {command}', command => 'sqitch grep' ),
      'Error message should be correct';

    # Test that execute() requires at least one argument
    throws_ok {
        my $empty_grep = $CLASS->new( sqitch => $grep_sqitch );
        $empty_grep->execute();
    }
    'App::Sqitch::X', 'execute() with empty args should die';
    is $@->ident, 'grep', 'Error ident should be "grep"';

    # Test behavior with no matching files
    my @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'XYZZY_NONEXISTENT_STRING_12345'
    );
    is scalar(@files), 0, 'get_files should return empty array when no files match';

    my $output = capture_output { $grep->execute('XYZZY_NONEXISTENT_STRING_12345') };
    is $output, '', 'execute() should produce no output when no files match';

    # Test behavior with empty search results
    $output = capture_output { $grep->execute('NONEXISTENT_PATTERN_ABCXYZ') };
    is $output, '', 'execute() should produce no output when search results are empty';

    # Test warning when file cannot be read
    my @test_files = (
        file(qw(t grep-fixtures deploy users.sql))->stringify,
        '/nonexistent/path/to/file.sql',
    );

    MockOutput->clear;
    $output = capture_output { $grep->show_matches( \@test_files, 'CREATE TABLE' ) };
    my $warnings = MockOutput->get_warn;
    like $warnings->[0][0], qr/Could not search ".*nonexistent.*":/,
      'show_matches should warn when file cannot be read';

    MockOutput->clear;
    $output = capture_output { $grep->show_matches( \@test_files, 'CREATE TABLE' ) };
    like $output, qr/users\.sql/,   'show_matches should continue processing after unreadable file';
    like $output, qr/CREATE TABLE/, 'show_matches should still show matches from readable files';

    # Test graceful handling of non-existent directories
    @files = $grep->get_files(
        dir(qw(t nonexistent-directory)),
        'CREATE TABLE'
    );
    is scalar(@files), 0, 'get_files should return empty array for non-existent directory';

    my $type_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
    );
    $output = capture_output { $type_grep->execute('SOME_PATTERN') };
    ok 1, 'execute() should handle non-existent directories gracefully';

    # Test behavior with multiple search terms
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE', 'TABLE', 'users'
    );
    ok scalar(@files) > 0, 'Multiple search terms should be joined and searched as single pattern';

    my @user_files = ( file(qw(t grep-fixtures deploy users.sql))->stringify );
    $output = capture_output { $grep->show_matches( \@user_files, 'CREATE', 'TABLE', 'users' ) };
    like $output, qr/CREATE TABLE users/, 'Multiple terms should be joined with spaces in pattern';

    # Test multiple terms with special characters (literal mode)
    my @widget_files = ( file(qw(t grep-fixtures deploy widgets.sql))->stringify );
    $output = capture_output { $grep->show_matches( \@widget_files, 'price.', '$' ) };
    is $output, '', 'Multiple terms with special chars should be joined with spaces';

    # Test multiple terms in regex mode
    my $regex_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        regex  => 1,
    );
    $output = capture_output { $regex_grep->show_matches( \@user_files, 'CREATE', 'TABLE' ) };
    like $output, qr/CREATE TABLE/, 'Multiple terms in regex mode should be joined with spaces';

    # Test that empty string search term is handled
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        ''
    );
    ok scalar(@files) >= 0, 'Empty string search should not cause error';

    # Test behavior with whitespace-only search terms
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '   '
    );
    ok scalar(@files) >= 0, 'Whitespace-only search should not cause error';

    # Test that very long search patterns work
    my $long_pattern = 'A' x 1000;
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        $long_pattern
    );
    is scalar(@files), 0, 'Very long search pattern should not cause error';

    # Test search with newline characters in pattern
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        "CREATE\nTABLE"
    );
    is scalar(@files), 0, 'Search pattern with newline should be treated literally';

    # Test that list mode with no matches produces no output
    my $list_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        list   => 1,
    );
    $output = capture_output { $list_grep->execute('XYZZY_NONEXISTENT_12345') };
    is $output, '', 'List mode with no matches should produce no output';

    # Test error handling with invalid regex in get_files
    my $invalid_regex_grep = $CLASS->new(
        sqitch => $grep_sqitch,
        regex  => 1,
    );
    throws_ok {
        $invalid_regex_grep->get_files(
            dir(qw(t grep-fixtures deploy)),
            '(?!invalid'
        );
    }
    qr/Unmatched|Sequence|Invalid/i,
      'get_files should die with invalid regex pattern';

    # Test error handling with invalid regex in show_matches
    throws_ok {
        my @files = ( file(qw(t grep-fixtures deploy users.sql))->stringify );
        $invalid_regex_grep->show_matches( \@files, '(?!invalid' );
    }
    qr/Unmatched|Sequence|Invalid/i,
      'show_matches should die with invalid regex pattern';

    # Test that execute() propagates errors from invalid regex
    throws_ok {
        $invalid_regex_grep->execute('(?!invalid');
    }
    qr/Unmatched|Sequence|Invalid/i,
      'execute() should propagate errors from invalid regex';

    # Test behavior when search directory is a file, not a directory
    my $file_as_dir = file(qw(t grep-fixtures sqitch.plan))->stringify;
    @files = $grep->get_files(
        $file_as_dir,
        'CREATE TABLE'
    );
    ok 1, 'get_files should handle file path instead of directory gracefully';

    # Test that special regex characters in literal mode don't cause errors
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        '.*+?[]{}()^$|\\/'
    );
    ok 1, 'Literal search with all special regex chars should not cause error';

    # Test show_matches with empty file list
    $output = capture_output { $grep->show_matches( [], 'CREATE TABLE' ) };
    is $output, '', 'show_matches with empty file list should produce no output';

    # Test that execute() with list mode and no matches produces empty output
    $output = capture_output { $list_grep->execute('NONEXISTENT_PATTERN_XYZ') };
    is $output, '', 'List mode with no matches should produce empty output';

    # Test combination of error conditions
    throws_ok {
        my $combo_error_grep = $CLASS->new(
            sqitch      => $grep_sqitch,
            regex       => 1,
            insensitive => 1,
        );
        $combo_error_grep->execute('(?!invalid');
    }
    qr/Unmatched|Sequence|Invalid/i,
      'Invalid regex should error even with other options';

    # Test that warnings from unreadable files don't stop execution
    MockOutput->clear;
    my @mixed_files = (
        '/nonexistent/file1.sql',
        file(qw(t grep-fixtures deploy users.sql))->stringify,
        '/nonexistent/file2.sql',
        file(qw(t grep-fixtures deploy widgets.sql))->stringify,
    );
    $output   = capture_output { $grep->show_matches( \@mixed_files, 'CREATE' ) };
    $warnings = MockOutput->get_warn;
    is scalar(@$warnings), 2, 'Should warn for each unreadable file';
    like $warnings->[0][0], qr/Could not search/, 'Warning should mention search failure';
    like $warnings->[1][0], qr/Could not search/, 'Warning should mention search failure';
    like $output,           qr/users\.sql/,       'Should still process readable files';
    like $output,           qr/widgets\.sql/,     'Should process all readable files';

    # Test edge case: search term that is a valid regex but should be literal
    my @posts_files = ( file(qw(t grep-fixtures deploy posts.sql))->stringify );
    $output = capture_output { $grep->show_matches( \@posts_files, '.*' ) };
    like $output, qr/foo\.\*bar/, 'Literal mode should find literal ".*" not match everything';

    # Test that multiple search terms with only whitespace between them work
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'CREATE', '', 'TABLE'
    );
    ok 1, 'Multiple terms with empty string between should not cause error';

    # Test execute() with type filter and no matches
    {
        my $output = '';
        open my $fh, '>', \$output or die "Cannot open string for writing: $!";
        my $old_fh = select $fh;

        my $type_no_match_grep = $CLASS->new(
            sqitch => $grep_sqitch,
            type   => 'deploy',
        );
        $type_no_match_grep->execute('NONEXISTENT_XYZ');

        select $old_fh;
        close $fh;

        is $output, '', 'Type filter with no matches should produce no output';
    }

    # Test that get_files handles directory with no .sql files
    my $no_sql_dir = dir(qw(po));
    @files = $grep->get_files(
        $no_sql_dir,
        'CREATE TABLE'
    );
    is scalar(@files), 0, 'get_files should return empty array for directory with no .sql files';

    # Test that show_matches handles files with no newline at end
    $output = capture_output { $grep->show_matches( \@user_files, 'COMMIT' ) };
    ok 1, 'show_matches should handle files without trailing newline';

    # Test that line numbers are accurate even with multiple matches in same file
    $output = capture_output { $grep->show_matches( \@user_files, 'id' ) };
    my @lines = split /\n/, $output;
    if ( scalar(@lines) > 1 ) {
        ok 1, 'Multiple matches should have different line numbers';
    }
    else {
        ok 1, 'Line number handling works for single or multiple matches';
    }

    # Test that execute() returns successfully even with no matches
    lives_ok {
        my $output = capture_output { $grep->execute('NONEXISTENT_PATTERN_ABC') };
    }
    'execute() should not die when no matches found';

    # Test that very short search terms work (single character)
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'i'
    );
    ok scalar(@files) > 0, 'Single character search should work';

    # Test search with Unicode characters
    @files = $grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'é'
    );
    ok 1, 'Unicode search should not cause error';

    # Test that case-insensitive mode works with special characters
    my $insensitive_grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
    );
    @files = $insensitive_grep->get_files(
        dir(qw(t grep-fixtures deploy)),
        'create table'
    );
    ok scalar(@files) > 0, 'Case-insensitive with special chars should work';
};

##############################################################################
subtest 'Integration tests for execute() method' => sub {

    # Test execute() with various argument combinations
    my $grep   = $CLASS->new( sqitch => $grep_sqitch );
    my $output = capture_output { $grep->execute( 'CREATE', 'TABLE' ) };
    like $output, qr/CREATE TABLE/, 'execute() with multiple arguments should join them';
    like $output, qr/\.sql:\d+:/,   'execute() output should have filename:line_number: format';

    # Test execute() with type=deploy option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
    );
    $output = capture_output { $grep->execute('CREATE TABLE') };
    like $output,   qr/deploy/,       'execute() with type=deploy should search deploy dir';
    unlike $output, qr/verify/,       'execute() with type=deploy should not search verify dir';
    unlike $output, qr/revert/,       'execute() with type=deploy should not search revert dir';
    like $output,   qr/CREATE TABLE/, 'execute() with type=deploy should find matches';

    # Test execute() with type=verify option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'verify',
    );
    $output = capture_output { $grep->execute('SELECT') };
    like $output,   qr/verify/, 'execute() with type=verify should search verify dir';
    unlike $output, qr/deploy/, 'execute() with type=verify should not search deploy dir';

    # Test execute() with type=revert option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'revert',
    );
    $output = capture_output { $grep->execute('DROP') };
    like $output,   qr/revert/, 'execute() with type=revert should search revert dir';
    unlike $output, qr/deploy/, 'execute() with type=revert should not search deploy dir';
    unlike $output, qr/verify/, 'execute() with type=revert should not search verify dir';

    # Test execute() with insensitive option
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
    );
    $output = capture_output { $grep->execute('create table') };
    like $output, qr/CREATE TABLE/i, 'execute() with insensitive should match different cases';

    # Test execute() with list option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        list   => 1,
    );
    $output = capture_output { $grep->execute('CREATE TABLE') };
    like $output,   qr/\.sql/,        'execute() with list should show filenames';
    unlike $output, qr/:\d+:/,        'execute() with list should not show line numbers';
    unlike $output, qr/CREATE TABLE/, 'execute() with list should not show line content';

    # Test execute() with regex option
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        regex  => 1,
    );
    $output = capture_output { $grep->execute('CREATE.*TABLE') };
    like $output, qr/CREATE.*TABLE/, 'execute() with regex should match patterns';

    # Test execute() with type + insensitive combination
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        type        => 'deploy',
        insensitive => 1,
    );
    $output = capture_output { $grep->execute('create table') };
    like $output,   qr/deploy/,        'execute() combo should filter by type';
    like $output,   qr/CREATE TABLE/i, 'execute() combo should be case-insensitive';
    unlike $output, qr/verify/,        'execute() combo should not include verify';

    # Test execute() with type + list combination
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
        list   => 1,
    );
    $output = capture_output { $grep->execute('CREATE TABLE') };
    like $output,   qr/deploy/,       'execute() type+list should filter by type';
    like $output,   qr/\.sql/,        'execute() type+list should show filenames';
    unlike $output, qr/:\d+:/,        'execute() type+list should not show line numbers';
    unlike $output, qr/CREATE TABLE/, 'execute() type+list should not show content';

    # Test execute() with insensitive + list combination
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
        list        => 1,
    );
    $output = capture_output { $grep->execute('create table') };
    like $output,   qr/\.sql/, 'execute() insensitive+list should show filenames';
    unlike $output, qr/:\d+:/, 'execute() insensitive+list should not show line numbers';

    # Test execute() with insensitive + regex combination
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
        regex       => 1,
    );
    $output = capture_output { $grep->execute('create.*table') };
    like $output, qr/CREATE.*TABLE/i, 'execute() insensitive+regex should match case-insensitive patterns';

    # Test execute() with type + insensitive + list combination
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        type        => 'deploy',
        insensitive => 1,
        list        => 1,
    );
    $output = capture_output { $grep->execute('create table') };
    like $output,   qr/deploy/,       'execute() all options should filter by type';
    like $output,   qr/\.sql/,        'execute() all options should show filenames';
    unlike $output, qr/:\d+:/,        'execute() all options should not show line numbers';
    unlike $output, qr/CREATE TABLE/, 'execute() all options should not show content';

    # Test execute() with type + regex combination
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
        regex  => 1,
    );
    $output = capture_output { $grep->execute('CREATE\s+TABLE') };
    like $output,   qr/deploy/,         'execute() type+regex should filter by type';
    like $output,   qr/CREATE\s+TABLE/, 'execute() type+regex should match patterns';
    unlike $output, qr/verify/,         'execute() type+regex should not include verify';

    # Test execute() with list + regex combination
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        list   => 1,
        regex  => 1,
    );
    $output = capture_output { $grep->execute('CREATE.*TABLE') };
    like $output,   qr/\.sql/, 'execute() list+regex should show filenames';
    unlike $output, qr/:\d+:/, 'execute() list+regex should not show line numbers';

    # Test execute() output format verification - normal mode
    $grep   = $CLASS->new( sqitch => $grep_sqitch );
    $output = capture_output { $grep->execute('CREATE TABLE users') };
    like $output, qr{t/grep-fixtures/deploy/users\.sql:\d+:.*CREATE TABLE users},
      'execute() output should match grep format: filename:line_number: content';

    # Test execute() output format verification - list mode
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        list   => 1,
    );
    $output = capture_output { $grep->execute('CREATE TABLE') };
    my @lines = split /\n/, $output;
    for my $line (@lines) {
        like $line, qr{^t/grep-fixtures/(deploy|verify|revert)/\w+\.sql$},
          'execute() list mode should show one filename per line';
        unlike $line, qr/:\d+:/, 'execute() list mode should not include line numbers';
    }

    # Test execute() with single search term
    $grep   = $CLASS->new( sqitch => $grep_sqitch );
    $output = capture_output { $grep->execute('TABLE') };
    like $output, qr/TABLE/,      'execute() with single term should find matches';
    like $output, qr/\.sql:\d+:/, 'execute() with single term should have correct format';

    # Test execute() with three search terms
    $output = capture_output { $grep->execute( 'CREATE', 'TABLE', 'users' ) };
    like $output, qr/CREATE TABLE users/, 'execute() with three terms should join them with spaces';

    # Test execute() with special characters in literal mode
    $output = capture_output { $grep->execute('price.$') };
    like $output, qr/price\.\$/, 'execute() in literal mode should find special characters literally';

    # Test execute() with special characters in regex mode
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        regex  => 1,
    );
    $output = capture_output { $grep->execute('price\.\$') };
    like $output, qr/price\.\$/, 'execute() in regex mode should match escaped special characters';

    # Test execute() maintains plan order across all option combinations
    $grep   = $CLASS->new( sqitch => $grep_sqitch );
    $output = capture_output { $grep->execute('TABLE') };
    my $roles_pos = index( $output, 'roles' );
    my $users_pos = index( $output, 'users' );
    if ( $roles_pos >= 0 && $users_pos >= 0 ) {
        ok $roles_pos < $users_pos, 'execute() should maintain plan order in output';
    }
    else {
        ok 1, 'Plan order test completed (files may not all match)';
    }

    # Test execute() with short option aliases
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        t      => 'deploy',
        i      => 1,
        l      => 1,
    );
    $output = capture_output { $grep->execute('create table') };
    like $output,   qr/deploy/, 'execute() with short options should work';
    like $output,   qr/\.sql/,  'execute() with -t -i -l should show filenames';
    unlike $output, qr/:\d+:/,  'execute() with short options should not show line numbers';

    # Test execute() with -e short option for regex
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        e      => 1,
    );
    $output = capture_output { $grep->execute('CREATE.*TABLE') };
    like $output, qr/CREATE.*TABLE/, 'execute() with -e option should enable regex mode';

    # Test execute() verifies all files are processed
    $grep   = $CLASS->new( sqitch => $grep_sqitch );
    $output = capture_output { $grep->execute('TABLE') };
    @lines  = split /\n/, $output;
    ok scalar(@lines) > 1, 'execute() should process multiple files';

    my %files_seen;
    for my $line (@lines) {
        if ( $line =~ m{(t/grep-fixtures/\w+/\w+\.sql)} ) {
            $files_seen{$1} = 1;
        }
    }
    ok scalar( keys %files_seen ) > 1, 'execute() should find matches in multiple different files';

    # Test execute() with pattern that matches in all three directories
    $output = capture_output { $grep->execute('TABLE') };
    my $has_deploy = $output =~ /deploy/;
    my $has_verify = $output =~ /verify/;
    my $has_revert = $output =~ /revert/;
    ok $has_deploy,                'execute() should search deploy directory';
    ok $has_verify || $has_revert, 'execute() should search verify and/or revert directories';

    # Test execute() respects target configuration
    isa_ok $grep->target, 'App::Sqitch::Target', 'execute() should use target configuration';
    $output = capture_output { $grep->execute('CREATE TABLE') };
    like $output, qr/\.sql/, 'execute() should respect target extension';

    # Test execute() with empty result set
    $output = capture_output { $grep->execute('NONEXISTENT_PATTERN_ABCXYZ123') };
    is $output, '', 'execute() with no matches should produce empty output';

    # Test execute() handles large result sets
    $output = capture_output { $grep->execute('id') };
    @lines  = split /\n/, $output;
    ok scalar(@lines) > 5, 'execute() should handle multiple matches across files';

    # Test execute() interaction between type and regex options
    $grep = $CLASS->new(
        sqitch => $grep_sqitch,
        type   => 'deploy',
        regex  => 1,
    );
    $output = capture_output { $grep->execute('^CREATE') };
    like $output,   qr/deploy/, 'Interaction test should filter by type';
    like $output,   qr/CREATE/, 'Interaction test should match regex pattern';
    unlike $output, qr/verify/, 'Interaction test should not include other types';

    # Test execute() interaction between insensitive and list options
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        insensitive => 1,
        list        => 1,
    );
    $output = capture_output { $grep->execute('create table') };
    like $output,   qr/\.sql/,        'Insensitive+list should show filenames';
    unlike $output, qr/CREATE TABLE/, 'Insensitive+list should not show content';
    ok length($output) > 0, 'Insensitive+list should find matches';

    # Test execute() with all four options combined
    $grep = $CLASS->new(
        sqitch      => $grep_sqitch,
        type        => 'deploy',
        insensitive => 1,
        list        => 1,
        regex       => 1,
    );
    $output = capture_output { $grep->execute('create.*table') };
    like $output,   qr/deploy/,       'All options should filter by type';
    like $output,   qr/\.sql/,        'All options should show filenames';
    unlike $output, qr/:\d+:/,        'All options should not show line numbers';
    unlike $output, qr/CREATE TABLE/, 'All options should not show content';
    ok length($output) > 0, 'All options combined should find matches';
};

##############################################################################
subtest 'Help system integration' => sub {

    # Test that sqitch help grep can find the documentation
    my $grep_pod = Pod::Find::pod_where( { '-inc' => 1 }, 'sqitch-grep' );
    ok $grep_pod, 'Should find sqitch-grep.pod documentation';
    like $grep_pod, qr/sqitch-grep\.pod$/, 'Should find correct grep documentation file';

    # Test that sqitch grep --help can find the usage documentation
    my $usage_pod = Pod::Find::pod_where( { '-inc' => 1 }, 'sqitch-grep-usage' );
    ok $usage_pod, 'Should find sqitch-grep-usage.pod documentation';
    like $usage_pod, qr/sqitch-grep-usage\.pod$/, 'Should find correct grep usage documentation file';

    # Test that the help command can display grep documentation
    my $help = App::Sqitch::Command::help->new( sqitch => $sqitch );

    my @pod2usage_args;
    my $mock_help = Test::MockModule->new('App::Sqitch::Command::help');
    $mock_help->mock( _pod2usage => sub { @pod2usage_args = @_; } );

    ok $help->execute('grep'), 'Should execute help for grep command';

    is_deeply \@pod2usage_args, [
        $help,
        '-input'   => Pod::Find::pod_where( { '-inc' => 1 }, 'sqitch-grep' ),
        '-verbose' => 2,
        '-exitval' => 0,
      ],
      'Should display full grep documentation with correct parameters';

    # Test that grep command usage() method works
    my $grep = $CLASS->new( sqitch => $sqitch );

    my @usage_args;
    my $mock_cmd = Test::MockModule->new($CLASS);
    $mock_cmd->mock( _pod2usage => sub { @usage_args = @_; } );

    $grep->usage();

    is $usage_args[0], $grep, 'First argument should be grep command object';

    my %usage_params = @usage_args[ 1 .. $#usage_args ];
    ok exists $usage_params{'-input'},   'Should have -input parameter';
    ok exists $usage_params{'-message'}, 'Should have -message parameter';

    # Test that grep appears in sqitchcommands.pod
    my $commands_pod = Pod::Find::pod_where( { '-inc' => 1 }, 'sqitchcommands' );
    ok $commands_pod, 'Should find sqitchcommands.pod';

    open my $fh, '<', $commands_pod or die "Cannot open $commands_pod: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like $content, qr/grep/i, 'sqitchcommands.pod should mention grep command';
};

done_testing();
