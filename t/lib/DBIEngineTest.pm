package DBIEngineTest;
use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use Test::More;
use Test::Exception;
use Time::HiRes qw(sleep tv_interval gettimeofday);
use Path::Class 0.33 qw(file dir);
use Digest::SHA qw(sha1_hex);
use Locale::TextDomain qw(App-Sqitch);
use File::Temp 'tempdir';

# Just die on warnings.
use Carp; BEGIN { $SIG{__WARN__} = \&Carp::confess }

sub randstr {
    my @s = (0..9,'a'..'z');
    join "", map $s[rand @s], 1..8;
}

sub run {
    my ( $self, %p ) = @_;

    my $class         = $p{class};
    my @sqitch_params = @{ $p{sqitch_params} || [] };
    my $user1_name    = 'Marge Simpson';
    my $user1_email   = 'marge@example.com';
    my $mock_sqitch   = Test::MockModule->new('App::Sqitch');

    # Mock script hashes using lines from the README.
    my $mock_change = Test::MockModule->new('App::Sqitch::Plan::Change');
    my @lines = grep { $_ } file('README.md')->slurp(
        chomp  => 1,
        iomode => '<:raw'
    );
    # Each change should retain its own hash.
    my $orig_deploy_hash;
    $mock_change->mock(_deploy_hash => sub {
        my $self = shift;
        $self->$orig_deploy_hash || sha1_hex shift @lines;
    });
    $orig_deploy_hash = $mock_change->original('_deploy_hash');

    can_ok $class, qw(
        initialized
        initialize
        run_file
        run_handle
        log_deploy_change
        log_fail_change
        log_revert_change
        earliest_change_id
        latest_change_id
        is_deployed_tag
        is_deployed_change
        change_id_for
        change_id_for_depend
        name_for_change_id
        change_offset_from_id
        change_id_offset_from_id
        load_change
        lock_destination
        try_lock
        wait_lock
    );

    subtest 'live database' => sub {
        my $sqitch = App::Sqitch->new(
            @sqitch_params,
            user_name  => $user1_name,
            user_email => $user1_email,
            config => TestConfig->new(
                'core.engine'    => $class->key,
                'core.top_dir'   => dir(qw(t engine))->stringify,
                'core.plan_file' => file(qw(t engine sqitch.plan))->stringify,
            )
        );
        my $target = App::Sqitch::Target->new(
            sqitch => $sqitch,
            @{ $p{target_params} || [] },
        );
        my $engine = $class->new(
            sqitch => $sqitch,
            target => $target,
            @{ $p{engine_params} || [] },
        );
        if (my $code = $p{skip_unless}) {
            try {
                $code->( $engine ) || die 'NO';
            } catch {
                (my $msg = eval { $_->message } || $_) =~ s/^/# /g;
                plan skip_all => sprintf(
                    'Unable to live-test %s engine: %s',
                    $class->name,
                    substr($msg, 2),
                ) unless $ENV{'LIVE_' . uc $engine->key . '_REQUIRED'};
                fail 'Connect to ' . $class->name;
                diag substr $msg, 2;
            } or return;
        }
        if (my $q = $p{version_query}) {
            say '# Connected to ', $engine->dbh->selectcol_arrayref($q)->[0];
        }
        ok $engine, 'Engine instantiated';

        ok !$engine->initialized, 'Database should not yet be initialized';
        OLDREG: {
            my $mock_file = Test::MockModule->new('Path::Class::File');
            my $dir = file(__FILE__)->dir->subdir('upgradable_registries');
            $mock_file->mock( dir => sub { $dir } );
            ok $engine->initialize, 'Initialize the database';
        };
        ok $engine->initialized, 'Database should now be initialized';
        ok !$engine->needs_upgrade, 'Registry should not need upgrading';
        my $get_releases = sub {
            my $releases = $engine->dbh->selectall_arrayref(q{
                SELECT version, installer_name, installer_email
                  FROM releases
                 ORDER BY version
            });
            $_->[0] = sprintf '%.1f', $_->[0] for @{ $releases };
            return $releases;
        };
        is_deeply $get_releases->(), [
            [$engine->registry_release + 0, $sqitch->user_name, $sqitch->user_email]
        ], 'The release should be registered';

        # Let's make sure upgrades work.
        $engine->dbh->do('DROP TABLE releases');
        ok $engine->needs_upgrade, 'Registry should need upgrading';
        MOCKINFO: {
            my $sqitch_mocker = Test::MockModule->new(ref $sqitch);
            my @args;
            $sqitch_mocker->mock(info => sub { shift; push @args => @_ });
            ok $engine->upgrade_registry, 'Upgrade the registry';
            is_deeply \@args, [__x(
                'Upgrading the Sqitch registry from {old} to {new}',
                old => 0,
                new => '1.1',
            ), '  * ' . __x(
                'From {old} to {new}',
                old => 0,
                new => '1.0',
            ), '  * ' . __x(
                'From {old} to {new}',
                old => '1.0',
                new => '1.1',
            )], 'Should have info output for upgrade';
        }
        ok !$engine->needs_upgrade, 'Registry should no longer need upgrading';
        is_deeply $get_releases->(), [
            [ '1.0', $sqitch->user_name, $sqitch->user_email ],
            [ '1.1', $sqitch->user_name, $sqitch->user_email ],
        ], 'The release should be registered again';

        # Try it with a different Sqitch DB.
        $target = App::Sqitch::Target->new(
            sqitch => $sqitch,
            @{ $p{alt_target_params} || [] },
        );
        ok $engine = $class->new(
            sqitch => $sqitch,
            target => $target,
            @{ $p{alt_engine_params} || [] },
        ), 'Create engine with alternate params';

        is $engine->earliest_change_id, undef, 'No init, earliest change';
        is $engine->latest_change_id, undef, 'No init, no latest change';

        ok !$engine->initialized, 'Database should no longer seem initialized';
        ok $engine->initialize, 'Initialize the database again';
        ok $engine->initialized, 'Database should be initialized again';
        ok !$engine->needs_upgrade, 'Registry should not need upgrading';

        is $engine->earliest_change_id, undef, 'Still no earlist change';
        is $engine->latest_change_id, undef, 'Still no latest changes';

        # Make sure a second attempt to initialize dies.
        throws_ok { $engine->initialize } 'App::Sqitch::X',
            'Should die on existing schema';
        is $@->ident, 'engine', 'Mode should be "engine"';
        is $@->message, $p{init_error},
            'And it should show the proper schema in the error message';

        throws_ok { $engine->dbh->do('INSERT blah INTO __bar_____') } 'App::Sqitch::X',
            'Database error should be converted to Sqitch exception';
        is $@->ident, $DBI::state, 'Ident should be SQL error state';
        like $@->message, $p{engine_err_regex}, 'The message should be from the engine';
        like $@->previous_exception, qr/DBD::[^:]+::db do failed: /,
            'The DBI error should be in preview_exception';

        is $engine->current_state, undef, 'Current state should be undef';
        is_deeply all( $engine->current_changes ), [], 'Should have no current changes';
        is_deeply all( $engine->current_tags ), [], 'Should have no current tags';
        is_deeply all( $engine->search_events ), [], 'Should have no events';

        ##########################################################################
        # Test the database connection, if appropriate.
        if (my $code = $p{test_dbh}) {
            $code->($engine->dbh);
        }

        ##########################################################################
        # Test register_project().
        can_ok $engine, 'register_project';
        can_ok $engine, 'registered_projects';

        is_deeply [ $engine->registered_projects ], [],
            'Should have no registered projects';

        ok $engine->register_project, 'Register the project';
        is_deeply [ $engine->registered_projects ], ['engine'],
            'Should have one registered project, "engine"';
        is_deeply $engine->dbh->selectall_arrayref(
            'SELECT project, uri, creator_name, creator_email FROM projects'
        ), [['engine', undef, $sqitch->user_name, $sqitch->user_email]],
            'The project should be registered';

        # Try to register it again.
        ok $engine->register_project, 'Register the project again';
        is_deeply [ $engine->registered_projects ], ['engine'],
            'Should still have one registered project, "engine"';
        is_deeply $engine->dbh->selectall_arrayref(
            'SELECT project, uri, creator_name, creator_email FROM projects'
        ), [['engine', undef, $sqitch->user_name, $sqitch->user_email]],
            'The project should still be registered only once';

        # Register a different project name.
        MOCKPROJECT: {
            my $plan_mocker = Test::MockModule->new(ref $target->plan );
            $plan_mocker->mock(project => 'groovy');
            $plan_mocker->mock(uri     => 'https://example.com/');
            ok $engine->register_project, 'Register a second project';
        }

        is_deeply [ $engine->registered_projects ], ['engine', 'groovy'],
            'Should have both registered projects';
        is_deeply $engine->dbh->selectall_arrayref(
            'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
        ), [
            ['engine', undef, $sqitch->user_name, $sqitch->user_email],
            ['groovy', 'https://example.com/', $sqitch->user_name, $sqitch->user_email],
        ], 'Both projects should now be registered';

        # Try to register with a different URI.
        MOCKURI: {
            my $plan_mocker = Test::MockModule->new(ref $target->plan );
            my $plan_proj = 'engine';
            my $plan_uri = 'https://example.net/';
            $plan_mocker->mock(project => sub { $plan_proj });
            $plan_mocker->mock(uri => sub { $plan_uri });
            throws_ok { $engine->register_project } 'App::Sqitch::X',
                'Should get an error for defined URI vs NULL registered URI';
            is $@->ident, 'engine', 'Defined URI error ident should be "engine"';
            is $@->message, __x(
                'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
                project => 'engine',
                uri     => $plan_uri,
            ), 'Defined URI error message should be correct';

            # Try it when the registered URI is NULL.
            $plan_proj = 'groovy';
            throws_ok { $engine->register_project } 'App::Sqitch::X',
                'Should get an error for different URIs';
            is $@->ident, 'engine', 'Different URI error ident should be "engine"';
            is $@->message, __x(
                'Cannot register "{project}" with URI {uri}: already exists with URI {reg_uri}',
                project => 'groovy',
                uri     => $plan_uri,
                reg_uri => 'https://example.com/',
            ), 'Different URI error message should be correct';

            # Try with a NULL project URI.
            $plan_uri  = undef;
            throws_ok { $engine->register_project } 'App::Sqitch::X',
                'Should get an error for NULL plan URI';
            is $@->ident, 'engine', 'NULL plan URI error ident should be "engine"';
            is $@->message, __x(
                'Cannot register "{project}" without URI: already exists with URI {uri}',
                project => 'groovy',
                uri     => 'https://example.com/',
            ), 'NULL plan uri error message should be correct';

            # It should succeed when the name and URI are the same.
            $plan_uri = 'https://example.com/';
            ok $engine->register_project, 'Register "groovy" again';
            is_deeply [ $engine->registered_projects ], ['engine', 'groovy'],
                'Should still have two registered projects';
            is_deeply $engine->dbh->selectall_arrayref(
                'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
            ), [
                ['engine', undef, $sqitch->user_name, $sqitch->user_email],
                ['groovy', 'https://example.com/', $sqitch->user_name, $sqitch->user_email],
            ], 'Both projects should still be registered';

            # Now try the same URI but a different name.
            $plan_proj = 'bob';
            throws_ok { $engine->register_project } 'App::Sqitch::X',
                'Should get error for an project with the URI';
            is $@->ident, 'engine', 'Existing URI error ident should be "engine"';
            is $@->message, __x(
                'Cannot register "{project}" with URI {uri}: project "{reg_proj}" already using that URI',
                project => $plan_proj,
                uri     => $plan_uri,
                reg_proj => 'groovy',
            ), 'Exising URI error message should be correct';
        }

        ######################################################################
        # Test log_deploy_change().
        my $plan = $target->plan;
        my $change = $plan->change_at(0);
        my ($tag) = $change->tags;
        is $change->name, 'users', 'Should have "users" change';
        ok !$engine->is_deployed_change($change), 'The change should not be deployed';
        is_deeply [$engine->are_deployed_changes($change)], [],
            'The change should not be deployed';

        ok $engine->log_deploy_change($change), 'Deploy "users" change';
        ok $engine->is_deployed_change($change), 'The change should now be deployed';
        is_deeply [$engine->are_deployed_changes($change)], [$change->id],
            'The change should now be deployed';

        is $engine->earliest_change_id, $change->id, 'Should get users ID for earliest change ID';
        is $engine->earliest_change_id(1), undef, 'Should get no change offset 1 from earliest';
        is $engine->latest_change_id, $change->id, 'Should get users ID for latest change ID';
        is $engine->latest_change_id(1), undef, 'Should get no change offset 1 from latest';

        is_deeply all_changes($engine), [[
            $change->id, 'users', 'engine', 'User roles', $sqitch->user_name, $sqitch->user_email,
            $change->planner_name, $change->planner_email,
        ]],'A record should have been inserted into the changes table';
        is_deeply get_dependencies($engine, $change->id), [], 'Should have no dependencies';
        is_deeply [ $engine->changes_requiring_change($change) ], [],
            'Change should not be required';


        my @event_data = ([
            'deploy',
            $change->id,
            'users',
            'engine',
            'User roles',
            $engine->_log_requires_param($change),
            $engine->_log_conflicts_param($change),
            $engine->_log_tags_param($change),
            $sqitch->user_name,
            $sqitch->user_email,
            $change->planner_name,
            $change->planner_email
        ]);

        is_deeply all_events($engine), \@event_data,
            'A record should have been inserted into the events table';

        is_deeply all_tags($engine), [[
            $tag->id,
            '@alpha',
            $change->id,
            'engine',
            'Good to go!',
            $sqitch->user_name,
            $sqitch->user_email,
            $tag->planner_name,
            $tag->planner_email,
        ]], 'The tag should have been logged';

        is $engine->name_for_change_id($change->id), 'users@alpha',
            'name_for_change_id() should return the change name with tag';

        ok my $state = $engine->current_state, 'Get the current state';
        isa_ok my $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
            'committed_at value';
        is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
        is_deeply $state, {
            project         => 'engine',
            change_id       => $change->id,
            script_hash     => $change->script_hash,
            change          => 'users',
            note            => 'User roles',
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            tags            => ['@alpha'],
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
            planned_at      => $change->timestamp,
        }, 'The rest of the state should look right';
        is_deeply all( $engine->current_changes ), [{
            change_id       => $change->id,
            script_hash     => $change->script_hash,
            change          => 'users',
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            committed_at    => $dt,
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
            planned_at      => $change->timestamp,
        }], 'Should have one current change';
        is_deeply all( $engine->current_tags('nonesuch') ), [],
            'Should have no current chnages for nonexistent project';
        is_deeply all( $engine->current_tags ), [{
            tag_id          => $tag->id,
            tag             => '@alpha',
            committed_at    => dt_for_tag( $engine, $tag->id ),
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            planner_name    => $tag->planner_name,
            planner_email   => $tag->planner_email,
            planned_at      => $tag->timestamp,
        }], 'Should have one current tags';
        is_deeply all( $engine->current_tags('nonesuch') ), [],
            'Should have no current tags for nonexistent project';
        my @events = ({
            event           => 'deploy',
            project         => 'engine',
            change_id       => $change->id,
            change          => 'users',
            note            => 'User roles',
            requires        => $engine->_log_requires_param($change),
            conflicts       => $engine->_log_conflicts_param($change),
            tags            => $engine->_log_tags_param($change),
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            committed_at    => dt_for_event($engine, 0),
            planned_at      => $change->timestamp,
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
        });
        is_deeply all( $engine->search_events ), \@events, 'Should have one event';

        ######################################################################
        # Test log_new_tags().
        ok $engine->log_new_tags($change), 'Log new tags for "users" change';
        is_deeply all_tags($engine), [[
            $tag->id,
            '@alpha',
            $change->id,
            'engine',
            'Good to go!',
            $sqitch->user_name,
            $sqitch->user_email,
            $tag->planner_name,
            $tag->planner_email,
        ]], 'The tag should be the same';

        # Delete that tag.
        $engine->dbh->do('DELETE FROM tags');
        is_deeply all_tags($engine), [], 'Should now have no tags';

        # Put it back.
        ok $engine->log_new_tags($change), 'Log new tags for "users" change again';
        is_deeply all_tags($engine), [[
            $tag->id,
            '@alpha',
            $change->id,
            'engine',
            'Good to go!',
            $sqitch->user_name,
            $sqitch->user_email,
            $tag->planner_name,
            $tag->planner_email,
        ]], 'The tag should be back';

        ######################################################################
        # Test log_revert_change(). First shift existing event dates.
        ok $engine->log_revert_change($change), 'Revert "users" change';
        ok !$engine->is_deployed_change($change), 'The change should no longer be deployed';
        is_deeply [$engine->are_deployed_changes($change)], [],
            'The change should no longer be deployed';

        is $engine->earliest_change_id, undef, 'Should get undef for earliest change';
        is $engine->latest_change_id, undef, 'Should get undef for latest change';

        is_deeply all_changes($engine), [],
            'The record should have been deleted from the changes table';
        is_deeply all_tags($engine), [], 'And the tag record should have been removed';
        is_deeply get_dependencies($engine, $change->id), [], 'Should still have no dependencies';
        is_deeply [ $engine->changes_requiring_change($change) ], [],
            'Change should not be required';

        push @event_data, [
            'revert',
            $change->id,
            'users',
            'engine',
            'User roles',
            $engine->_log_requires_param($change),
            $engine->_log_conflicts_param($change),
            $engine->_log_tags_param($change),
            $sqitch->user_name,
            $sqitch->user_email,
            $change->planner_name,
            $change->planner_email
        ];

        is_deeply all_events($engine), \@event_data,
            'The revert event should have been logged';

        is $engine->name_for_change_id($change->id), undef,
            'name_for_change_id() should no longer return the change name';
        is $engine->current_state, undef, 'Current state should be undef again';
        is_deeply all( $engine->current_changes ), [],
            'Should again have no current changes';
        is_deeply all( $engine->current_tags ), [], 'Should again have no current tags';

        unshift @events => {
            event           => 'revert',
            project         => 'engine',
            change_id       => $change->id,
            change          => 'users',
            note            => 'User roles',
            requires        => $engine->_log_requires_param($change),
            conflicts       => $engine->_log_conflicts_param($change),
            tags            => $engine->_log_tags_param($change),
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            committed_at    => dt_for_event($engine, 1),
            planned_at      => $change->timestamp,
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
        };
        is_deeply all( $engine->search_events ), \@events, 'Should have two events';

        ######################################################################
        # Test log_fail_change().
        ok $engine->log_fail_change($change), 'Fail "users" change';
        ok !$engine->is_deployed_change($change), 'The change still should not be deployed';
        is_deeply [$engine->are_deployed_changes($change)], [],
            'The change still should not be deployed';
        is $engine->earliest_change_id, undef, 'Should still get undef for earliest change';
        is $engine->latest_change_id, undef, 'Should still get undef for latest change';
        is_deeply all_changes($engine), [], 'Still should have not changes table record';
        is_deeply all_tags($engine), [], 'Should still have no tag records';
        is_deeply get_dependencies($engine, $change->id), [], 'Should still have no dependencies';
        is_deeply [ $engine->changes_requiring_change($change) ], [],
            'Change should not be required';

        push @event_data, [
            'fail',
            $change->id,
            'users',
            'engine',
            'User roles',
            $engine->_log_requires_param($change),
            $engine->_log_conflicts_param($change),
            $engine->_log_tags_param($change),
            $sqitch->user_name,
            $sqitch->user_email,
            $change->planner_name,
            $change->planner_email
        ];

        is_deeply all_events($engine), \@event_data, 'The fail event should have been logged';
        is $engine->current_state, undef, 'Current state should still be undef';
        is_deeply all( $engine->current_changes ), [], 'Should still have no current changes';
        is_deeply all( $engine->current_tags ), [], 'Should still have no current tags';

        unshift @events => {
            event           => 'fail',
            project         => 'engine',
            change_id       => $change->id,
            change          => 'users',
            note            => 'User roles',
            requires        => $engine->_log_requires_param($change),
            conflicts       => $engine->_log_conflicts_param($change),
            tags            => $engine->_log_tags_param($change),
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            committed_at    => dt_for_event($engine, 2),
            planned_at      => $change->timestamp,
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
        };
        is_deeply all( $engine->search_events ), \@events, 'Should have 3 events';

        # From here on in, use a different committer.
        my $user2_name  = 'Homer Simpson';
        my $user2_email = 'homer@example.com';
        $mock_sqitch->mock( user_name => $user2_name );
        $mock_sqitch->mock( user_email => $user2_email );

        ######################################################################
        # Test a change with dependencies.
        ok $engine->log_deploy_change($change),    'Deploy the change again';
        ok $engine->is_deployed_tag($tag),     'The tag again should be deployed';
        is $engine->earliest_change_id, $change->id, 'Should again get users ID for earliest change ID';
        is $engine->earliest_change_id(1), undef, 'Should still get no change offset 1 from earliest';
        is $engine->latest_change_id, $change->id, 'Should again get users ID for latest change ID';
        is $engine->latest_change_id(1), undef, 'Should still get no change offset 1 from latest';

        ok my $change2 = $plan->change_at(1),   'Get the second change';
        is_deeply [sort $engine->are_deployed_changes($change, $change2)], [$change->id],
            'Only the first change should be deployed';
        my ($req) = $change2->requires;
        ok $req->resolved_id($change->id),      'Set resolved ID in required depend';
        # Send this change back in time.
        $engine->dbh->do(
            'UPDATE changes SET committed_at = ?',
                undef, '2013-03-30 00:47:47',
        );
        ok $engine->log_deploy_change($change2),    'Deploy second change';
        is $engine->earliest_change_id, $change->id, 'Should still get users ID for earliest change ID';
        is $engine->earliest_change_id(1), $change2->id,
            'Should get "widgets" offset 1 from earliest';
        is $engine->earliest_change_id(2), undef, 'Should get no change offset 2 from earliest';
        is $engine->latest_change_id, $change2->id, 'Should get "widgets" ID for latest change ID';
        is $engine->latest_change_id(1), $change->id,
            'Should get "user" offset 1 from earliest';
        is $engine->latest_change_id(2), undef, 'Should get no change offset 2 from latest';

        is_deeply all_changes($engine), [
            [
                $change->id,
                'users',
                'engine',
                'User roles',
                $user2_name,
                $user2_email,
                $change->planner_name,
                $change->planner_email,
            ],
            [
                $change2->id,
                'widgets',
                'engine',
                'All in',
                $user2_name,
                $user2_email,
                $change2->planner_name,
                $change2->planner_email,
            ],
        ], 'Should have both changes and requires/conflcits deployed';
        is_deeply [sort $engine->are_deployed_changes($change, $change2)],
            [sort $change->id, $change2->id],
            'Both changes should be deployed';
        is_deeply get_dependencies($engine, $change->id), [],
            'Should still have no dependencies for "users"';
        is_deeply get_dependencies($engine, $change2->id), [
            [
                $change2->id,
                'conflict',
                'dr_evil',
                undef,
            ],
            [
                $change2->id,
                'require',
                'users',
                $change->id,
            ],
        ], 'Should have both dependencies for "widgets"';

        is_deeply [ $engine->changes_requiring_change($change) ], [{
            project   => 'engine',
            change_id => $change2->id,
            change    => 'widgets',
            asof_tag  => undef,
        }], 'Change "users" should be required by "widgets"';
        is_deeply [ $engine->changes_requiring_change($change2) ], [],
            'Change "widgets" should not be required';

        push @event_data, [
            'deploy',
            $change->id,
            'users',
            'engine',
            'User roles',
            $engine->_log_requires_param($change),
            $engine->_log_conflicts_param($change),
            $engine->_log_tags_param($change),
            $user2_name,
            $user2_email,
            $change->planner_name,
            $change->planner_email,
        ], [
            'deploy',
            $change2->id,
            'widgets',
            'engine',
            'All in',
            $engine->_log_requires_param($change2),
            $engine->_log_conflicts_param($change2),
            $engine->_log_tags_param($change2),
            $user2_name,
            $user2_email,
            $change2->planner_name,
            $change2->planner_email,
        ];
        is_deeply all_events($engine), \@event_data,
            'The new change deploy should have been logged';

        is $engine->name_for_change_id($change2->id), 'widgets@HEAD',
            'name_for_change_id() should return name with symbolic tag @HEAD';

        ok $state = $engine->current_state, 'Get the current state again';
        isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
            'committed_at value';
        is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
        is_deeply $state, {
            project         => 'engine',
            change_id       => $change2->id,
            script_hash     => $change2->script_hash,
            change          => 'widgets',
            note            => 'All in',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
            tags            => [],
        }, 'The state should reference new change';

        my @current_changes = (
            {
                change_id       => $change2->id,
                script_hash     => $change2->script_hash,
                change          => 'widgets',
                committer_name  => $user2_name,
                committer_email => $user2_email,
                committed_at    => dt_for_change( $engine, $change2->id ),
                planner_name    => $change2->planner_name,
                planner_email   => $change2->planner_email,
                planned_at      => $change2->timestamp,
            },
            {
                change_id       => $change->id,
                script_hash     => $change->script_hash,
                change          => 'users',
                committer_name  => $user2_name,
                committer_email => $user2_email,
                committed_at    => dt_for_change( $engine, $change->id ),
                planner_name    => $change->planner_name,
                planner_email   => $change->planner_email,
                planned_at      => $change->timestamp,
            },
        );

        is_deeply all( $engine->current_changes ), \@current_changes,
            'Should have two current changes in reverse chronological order';

        my @current_tags = (
            {
                tag_id     => $tag->id,
                tag        => '@alpha',
                committer_name  => $user2_name,
                committer_email => $user2_email,
                committed_at    => dt_for_tag( $engine, $tag->id ),
                planner_name    => $tag->planner_name,
                planner_email   => $tag->planner_email,
                planned_at      => $tag->timestamp,
            },
        );
        is_deeply all( $engine->current_tags ), \@current_tags,
            'Should again have one current tags';

        unshift @events => {
            event           => 'deploy',
            project         => 'engine',
            change_id       => $change2->id,
            change          => 'widgets',
            note            => 'All in',
            requires        => $engine->_log_requires_param($change2),
            conflicts       => $engine->_log_conflicts_param($change2),
            tags            => $engine->_log_tags_param($change2),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 4),
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
        }, {
            event           => 'deploy',
            project         => 'engine',
            change_id       => $change->id,
            change          => 'users',
            note            => 'User roles',
            requires        => $engine->_log_requires_param($change),
            conflicts       => $engine->_log_conflicts_param($change),
            tags            => $engine->_log_tags_param($change),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 3),
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
            planned_at      => $change->timestamp,
        };
        is_deeply all( $engine->search_events ), \@events, 'Should have 5 events';

        ######################################################################
        # Test deployed_changes(), deployed_changes_since(), load_change, and
        # change_offset_from_id(), and change_id_offset_from_id()
        can_ok $engine, qw(
            deployed_changes
            deployed_changes_since
            load_change
            change_offset_from_id
            change_id_offset_from_id
        );
        my $change_hash = {
            id            => $change->id,
            name          => $change->name,
            project       => $change->project,
            note          => $change->note,
            timestamp     => $change->timestamp,
            planner_name  => $change->planner_name,
            planner_email => $change->planner_email,
            tags          => ['@alpha'],
            script_hash   => $change->script_hash,
        };
        my $change2_hash = {
            id            => $change2->id,
            name          => $change2->name,
            project       => $change2->project,
            note          => $change2->note,
            timestamp     => $change2->timestamp,
            planner_name  => $change2->planner_name,
            planner_email => $change2->planner_email,
            tags          => [],
            script_hash   => $change2->script_hash,
        };

        is_deeply [$engine->deployed_changes], [$change_hash, $change2_hash],
            'Should have two deployed changes';
        is_deeply [$engine->deployed_changes_since($change)], [$change2_hash],
            'Should find one deployed since the first one';
        is_deeply [$engine->deployed_changes_since($change2)], [],
            'Should find none deployed since the second one';

        is_deeply $engine->load_change($change->id), $change_hash,
            'Should load change 1';
        is_deeply $engine->load_change($change2->id), $change2_hash,
            'Should load change 2';
        is_deeply $engine->load_change('whatever'), undef,
            'load() should return undef for uknown change ID';

        is_deeply $engine->change_offset_from_id($change->id, undef), $change_hash,
            'Should load change with no offset';
        is_deeply $engine->change_offset_from_id($change2->id, 0), $change2_hash,
            'Should load change with offset 0';

        is_deeply $engine->change_id_offset_from_id($change->id, undef), $change->id,
            'Should get change ID with no offset';
        is_deeply $engine->change_id_offset_from_id($change2->id, 0), $change2->id,
            'Should get change ID with offset 0';

        # Now try some offsets.
        is_deeply $engine->change_offset_from_id($change->id, 1), $change2_hash,
            'Should find change with offset 1';
        is_deeply $engine->change_offset_from_id($change2->id, -1), $change_hash,
            'Should find change with offset -1';
        is_deeply $engine->change_offset_from_id($change->id, 2), undef,
            'Should find undef change with offset 2';

        is_deeply $engine->change_id_offset_from_id($change->id, 1), $change2->id,
            'Should find change ID with offset 1';
        is_deeply $engine->change_id_offset_from_id($change2->id, -1), $change->id,
            'Should find change ID with offset -1';
        is_deeply $engine->change_id_offset_from_id($change->id, 2), undef,
            'Should find undef change ID with offset 2';

        # Revert change 2.
        ok $engine->log_revert_change($change2), 'Revert "widgets"';
        is_deeply [$engine->deployed_changes], [$change_hash],
            'Should now have one deployed change ID';
        is_deeply [$engine->deployed_changes_since($change)], [],
            'Should find none deployed since that one';

        # Add another one.
        ok $engine->log_deploy_change($change2), 'Log another change';
        is_deeply [$engine->deployed_changes], [$change_hash, $change2_hash],
            'Should have both deployed change IDs';
        is_deeply [$engine->deployed_changes_since($change)], [$change2_hash],
            'Should find only the second after the first';
        is_deeply [$engine->deployed_changes_since($change2)], [],
            'Should find none after the second';

        ok $state = $engine->current_state, 'Get the current state once more';
        isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
            'committed_at value';
        is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
        is_deeply $state, {
            project         => 'engine',
            change_id       => $change2->id,
            script_hash     => $change2->script_hash,
            change          => 'widgets',
            note            => 'All in',
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            tags            => [],
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
        }, 'The new state should reference latest change';

        # These were reverted and re-deployed, so might have new timestamps.
        $current_changes[0]->{committed_at} = dt_for_change( $engine, $change2->id );
        $current_changes[1]->{committed_at} = dt_for_change( $engine, $change->id );
        is_deeply all( $engine->current_changes ), \@current_changes,
            'Should still have two current changes in reverse chronological order';
        is_deeply all( $engine->current_tags ), \@current_tags,
            'Should still have one current tags';

        unshift @events => {
            event           => 'deploy',
            project         => 'engine',
            change_id       => $change2->id,
            change          => 'widgets',
            note            => 'All in',
            requires        => $engine->_log_requires_param($change2),
            conflicts       => $engine->_log_conflicts_param($change2),
            tags            => $engine->_log_tags_param($change2),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 6),
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
        }, {
            event           => 'revert',
            project         => 'engine',
            change_id       => $change2->id,
            change          => 'widgets',
            note            => 'All in',
            requires        => $engine->_log_requires_param($change2),
            conflicts       => $engine->_log_conflicts_param($change2),
            tags            => $engine->_log_tags_param($change2),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 5),
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
        };
        is_deeply all( $engine->search_events ), \@events, 'Should have 7 events';

        ######################################################################
        # Deploy the new changes with two tags.
        $plan->add( name => 'fred',   note => 'Hello Fred' );
        $plan->add( name => 'barney', note => 'Hello Barney' );
        $plan->tag( name => 'beta',   note => 'Note beta' );
        $plan->tag( name => 'gamma',  note => 'Note gamma' );
        ok my $fred = $plan->get('fred'),       'Get the "fred" change';
        ok $engine->log_deploy_change($fred),   'Deploy "fred"';
        sleep 0.1; # Give SQLite a little time to tick microseconds.
        ok my $barney = $plan->get('barney'),   'Get the "barney" change';
        ok $engine->log_deploy_change($barney), 'Deploy "barney"';

        is $engine->earliest_change_id, $change->id, 'Earliest change should sill be "users"';
        is $engine->earliest_change_id(1), $change2->id,
            'Should still get "widgets" offset 1 from earliest';
        is $engine->earliest_change_id(2), $fred->id,
            'Should get "fred" offset 2 from earliest';
        is $engine->earliest_change_id(3), $barney->id,
            'Should get "barney" offset 3 from earliest';

        is $engine->latest_change_id,    $barney->id,  'Latest change should be "barney"';
        is $engine->latest_change_id(1), $fred->id,    'Should get "fred" offset 1 from latest';
        is $engine->latest_change_id(2), $change2->id, 'Should get "widgets" offset 2 from latest';
        is $engine->latest_change_id(3), $change->id,  'Should get "users" offset 3 from latest';

        $state = $engine->current_state;
        # MySQL's group_concat(), Oracle's collect(), and Yugabyte's array_agg()
        # do not by default sort by row order, alas.
        $state->{tags} = [ sort @{ $state->{tags} } ]
            if $class =~ /::(?:mysql|oracle)$/ || try { $engine->_provider eq 'yugabyte' };
        is_deeply $state, {
            project         => 'engine',
            change_id       => $barney->id,
            script_hash     => $barney->script_hash,
            change          => 'barney',
            note            => 'Hello Barney',
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            committed_at    => dt_for_change( $engine,$barney->id),
            tags            => [qw(@beta @gamma)],
            planner_name    => $barney->planner_name,
            planner_email   => $barney->planner_email,
            planned_at      => $barney->timestamp,
        }, 'Barney should be in the current state';

        unshift @current_changes => {
            change_id       => $barney->id,
            script_hash     => $barney->script_hash,
            change          => 'barney',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $engine, $barney->id ),
            planner_name    => $barney->planner_name,
            planner_email   => $barney->planner_email,
            planned_at      => $barney->timestamp,
        }, {
            change_id       => $fred->id,
            script_hash     => $fred->script_hash,
            change          => 'fred',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $engine, $fred->id ),
            planner_name    => $fred->planner_name,
            planner_email   => $fred->planner_email,
            planned_at      => $fred->timestamp,
        };

        is_deeply all( $engine->current_changes ), \@current_changes,
            'Should have all four current changes in reverse chron order';

        my ($beta, $gamma) = $barney->tags;
        if (my $format = $p{add_second_format}) {
            my $set = sprintf $format, 'committed_at';
            $engine->dbh->do(
                "UPDATE tags SET committed_at = $set WHERE tag = '\@gamma'"
            );
        }
        unshift @current_tags => {
            tag_id          => $gamma->id,
            tag             => '@gamma',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_tag( $engine, $gamma->id ),
            planner_name    => $gamma->planner_name,
            planner_email   => $gamma->planner_email,
            planned_at      => $gamma->timestamp,
        }, {
            tag_id          => $beta->id,
            tag             => '@beta',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_tag( $engine, $beta->id ),
            planner_name    => $beta->planner_name,
            planner_email   => $beta->planner_email,
            planned_at      => $beta->timestamp,
        };

        is_deeply all( $engine->current_tags ), \@current_tags,
            'Should now have three current tags in reverse chron order';

        unshift @events => {
            event           => 'deploy',
            project         => 'engine',
            change_id       => $barney->id,
            change          => 'barney',
            note            => 'Hello Barney',
            requires        => $engine->_log_requires_param($barney),
            conflicts       => $engine->_log_conflicts_param($barney),
            tags            => $engine->_log_tags_param($barney),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 8),
            planner_name    => $barney->planner_name,
            planner_email   => $barney->planner_email,
            planned_at      => $barney->timestamp,
        }, {
            event           => 'deploy',
            project         => 'engine',
            change_id       => $fred->id,
            change          => 'fred',
            note            => 'Hello Fred',
            requires        => $engine->_log_requires_param($fred),
            conflicts       => $engine->_log_conflicts_param($fred),
            tags            => $engine->_log_tags_param($fred),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 7),
            planner_name    => $fred->planner_name,
            planner_email   => $fred->planner_email,
            planned_at      => $fred->timestamp,
        };
        is_deeply all( $engine->search_events ), \@events, 'Should have 9 events';

        ######################################################################
        # Test search_events() parameters.
        is_deeply all( $engine->search_events(limit => 2) ), [ @events[0..1] ],
            'The limit param to search_events should work';

        is_deeply all( $engine->search_events(offset => 4) ), [ @events[4..$#events] ],
            'The offset param to search_events should work';

        is_deeply all( $engine->search_events(limit => 3, offset => 4) ), [ @events[4..6] ],
            'The limit and offset params to search_events should work together';

        is_deeply all( $engine->search_events( direction => 'DESC' ) ), \@events,
            'Should work to set direction "DESC" in search_events';
        is_deeply all( $engine->search_events( direction => 'desc' ) ), \@events,
            'Should work to set direction "desc" in search_events';
        is_deeply all( $engine->search_events( direction => 'descending' ) ), \@events,
            'Should work to set direction "descending" in search_events';

        is_deeply all( $engine->search_events( direction => 'ASC' ) ),
            [ reverse @events ],
            'Should work to set direction "ASC" in search_events';
        is_deeply all( $engine->search_events( direction => 'asc' ) ),
            [ reverse @events ],
            'Should work to set direction "asc" in search_events';
        is_deeply all( $engine->search_events( direction => 'ascending' ) ),
            [ reverse @events ],
            'Should work to set direction "ascending" in search_events';
        throws_ok { $engine->search_events( direction => 'foo' ) } 'App::Sqitch::X',
            'Should catch exception for invalid search direction';
        is $@->ident, 'DEV', 'Search direction error ident should be "DEV"';
        is $@->message, 'Search direction must be either "ASC" or "DESC"',
            'Search direction error message should be correct';

        is_deeply all( $engine->search_events( committer => 'Simpson$' ) ), \@events,
            'The committer param to search_events should work';
        is_deeply all( $engine->search_events( committer => "^Homer" ) ),
            [ @events[0..5] ],
            'The committer param to search_events should work as a regex';
        is_deeply all( $engine->search_events( committer => 'Simpsonized$' ) ), [],
            qq{Committer regex should fail to match with "Simpsonized\$"};

        is_deeply all( $engine->search_events( change => 'users' ) ),
            [ @events[5..$#events] ],
            'The change param to search_events should work with "users"';
        is_deeply all( $engine->search_events( change => 'widgets' ) ),
            [ @events[2..4] ],
            'The change param to search_events should work with "widgets"';
        is_deeply all( $engine->search_events( change => 'fred' ) ),
            [ $events[1] ],
            'The change param to search_events should work with "fred"';
        is_deeply all( $engine->search_events( change => 'fre$' ) ), [],
            'The change param to search_events should return nothing for "fre$"';
        is_deeply all( $engine->search_events( change => '(er|re)' ) ),
            [@events[1, 5..8]],
            'The change param to search_events should return match "(er|re)"';

        is_deeply all( $engine->search_events( event => [qw(deploy)] ) ),
            [ grep { $_->{event} eq 'deploy' } @events ],
            'The event param should work with "deploy"';
        is_deeply all( $engine->search_events( event => [qw(revert)] ) ),
            [ grep { $_->{event} eq 'revert' } @events ],
            'The event param should work with "revert"';
        is_deeply all( $engine->search_events( event => [qw(fail)] ) ),
            [ grep { $_->{event} eq 'fail' } @events ],
            'The event param should work with "fail"';
        is_deeply all( $engine->search_events( event => [qw(revert fail)] ) ),
            [ grep { $_->{event} ne 'deploy' } @events ],
            'The event param should work with "revert" and "fail"';
        is_deeply all( $engine->search_events( event => [qw(deploy revert fail)] ) ),
            \@events,
            'The event param should work with "deploy", "revert", and "fail"';
        is_deeply all( $engine->search_events( event => ['foo'] ) ), [],
            'The event param should return nothing for "foo"';

        # Add an external project event.
        ok my $ext_plan = App::Sqitch::Plan->new(
            sqitch  => $sqitch,
            target  => $target,
            project => 'groovy',
        ), 'Create external plan';
        ok my $ext_change = $ext_plan->add(
            plan => $ext_plan,
            name => 'crazyman',
            note => 'Crazy, right?',
        ), "Create external change";

        # Because we're gonna use a regular expression on events.project to
        # get events from multiple projects, we need to make sure that we get
        # things in the proper order, such as on MySQL 5.5, where there is no
        # datetime precision. So pretend we're about to insert another
        # "engine" project record to get the MySQL engine to wait out a clock
        # second tick before inserting our "groovy" change. This is purely so
        # we get things back in the proper order for the `project => 'g'` test
        # below. In reality it shouldn't matter much.
        $engine->_prepare_to_log(events => $barney);

        ok $engine->log_deploy_change($ext_change), 'Log the external change';
        my $ext_event = {
            event           => 'deploy',
            project         => 'groovy',
            change_id       => $ext_change->id,
            change          => $ext_change->name,
            note            => $ext_change->note,
            requires        => $engine->_log_requires_param($ext_change),
            conflicts       => $engine->_log_conflicts_param($ext_change),
            tags            => $engine->_log_tags_param($ext_change),
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_event($engine, 9),
            planner_name    => $user2_name,
            planner_email   => $user2_email,
            planned_at      => $ext_change->timestamp,
        };
        is_deeply all( $engine->search_events( project => '^engine$' ) ), \@events,
            'The project param to search_events should work';
        is_deeply all( $engine->search_events( project => '^groovy$' ) ), [$ext_event],
            'The project param to search_events should work with external project';
        is_deeply all( $engine->search_events( project => 'g' ) ), [$ext_event, @events],
            'The project param to search_events should match across projects';
        is_deeply all( $engine->search_events( project => 'nonexistent' ) ), [],
            qq{Project regex should fail to match with "nonexistent"};

        # Make sure we do not see these changes where we should not.
        ok !grep( { $_ eq $ext_change->id } $engine->deployed_changes),
            'deployed_changes should not include external change';
        ok !grep( { $_ eq $ext_change->id } $engine->deployed_changes_since($change)),
            'deployed_changes_since should not include external change';

        is $engine->earliest_change_id, $change->id,
            'Earliest change should sill be "users"';
        isnt $engine->latest_change_id, $ext_change->id,
            'Latest change ID should not be from external project';

        throws_ok { $engine->search_events(foo => 1) } 'App::Sqitch::X',
            'Should catch exception for invalid search param';
        is $@->ident, 'DEV', 'Invalid search param error ident should be "DEV"';
        is $@->message, 'Invalid parameters passed to search_events(): foo',
            'Invalid search param error message should be correct';

        throws_ok { $engine->search_events(foo => 1, bar => 2) } 'App::Sqitch::X',
            'Should catch exception for invalid search params';
        is $@->ident, 'DEV', 'Invalid search params error ident should be "DEV"';
        is $@->message, 'Invalid parameters passed to search_events(): bar, foo',
            'Invalid search params error message should be correct';

        ######################################################################
        # Now that we have a change from an externa project, get its state.
        ok $state = $engine->current_state('groovy'), 'Get the "groovy" state';
        isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
            'groofy committed_at value';
        is $dt->time_zone->name, 'UTC', 'groovy committed_at TZ should be UTC';
        is_deeply $state, {
            project         => 'groovy',
            change_id       => $ext_change->id,
            script_hash     => $ext_change->script_hash,
            change          => $ext_change->name,
            note            => $ext_change->note,
            committer_name  => $sqitch->user_name,
            committer_email => $sqitch->user_email,
            tags            => [],
            planner_name    => $ext_change->planner_name,
            planner_email   => $ext_change->planner_email,
            planned_at      => $ext_change->timestamp,
        }, 'The rest of the state should look right';

        ######################################################################
        # Test change_id_for().
        for my $spec (
            [
                'change_id only',
                { change_id => $change->id },
                $change->id,
            ],
            [
                'change only',
                { change => $change->name },
                $change->id,
            ],
            [
                'change + tag',
                { change => $change->name, tag => 'alpha' },
                $change->id,
            ],
            [
                'change@HEAD',
                { change => $change->name, tag => 'HEAD' },
                $change->id,
            ],
            [
                'tag only',
                { tag => 'alpha' },
                $change->id,
            ],
            [
                'ROOT',
                { tag => 'ROOT' },
                $change->id,
            ],
            [
                'HEAD',
                { tag => 'HEAD' },
                $barney->id,
            ],
            [
                'project:ROOT',
                { tag => 'ROOT', project => 'groovy' },
                $ext_change->id,
            ],
            [
                'project:HEAD',
                { tag => 'HEAD', project => 'groovy' },
                $ext_change->id,
            ],
        ) {
            my ( $desc, $params, $exp_id ) = @{ $spec };
            is $engine->change_id_for(%{ $params }), $exp_id, "Should find id for $desc";
        }

        for my $spec (
            [
                'unkonwn id',
                { change_id => 'whatever' },
            ],
            [
                'unkonwn change',
                { change => 'whatever' },
            ],
            [
                'unkonwn tag',
                { tag => 'whatever' },
            ],
            [
                'change + unkonwn tag',
                { change => $change->name, tag => 'whatever' },
            ],
            [
                'change@ROOT',
                { change => $change->name, tag => 'ROOT' },
            ],
            [
                'change + different project',
                { change => $change->name, project => 'whatever' },
            ],
            [
                'tag + different project',
                { tag => 'alpha', project => 'whatever' },
            ],
        ) {
            my ( $desc, $params ) = @{ $spec };
            is $engine->change_id_for(%{ $params }), undef, "Should find nothing for $desc";
        }

        ######################################################################
        # Test change_id_for_depend().
        my $id = '4f1e83f409f5f533eeef9d16b8a59e2c0aa91cc1';
        my $i;

        for my $spec (
            [
                'id only',
                { id => $id },
                { id => $id },
            ],
            [
                'change + tag',
                { change => 'bart', tag => 'epsilon' },
                { name   => 'bart' }
            ],
            [
                'change only',
                { change => 'lisa' },
                { name   => 'lisa' },
            ],
            [
                'tag only',
                { tag  => 'sigma' },
                { name => 'maggie' },
            ],
        ) {
            my ( $desc, $dep_params, $chg_params ) = @{ $spec };

            # Test as an internal dependency.
            INTERNAL: {
                ok my $change = $plan->add(
                    name    => 'foo' . ++$i,
                    %{$chg_params},
                ), "Create internal $desc change";

                # Tag it if necessary.
                if (my $tag = $dep_params->{tag}) {
                    ok $plan->tag(name => $tag), "Add tag internal \@$tag";
                }

                # Should start with unsatisfied dependency.
                ok my $dep = App::Sqitch::Plan::Depend->new(
                    plan    => $plan,
                    project => $plan->project,
                    %{ $dep_params },
                ), "Create internal $desc dependency";
                is $engine->change_id_for_depend($dep), undef,
                    "Internal $desc depencency should not be satisfied";

                # Once deployed, dependency should be satisfied.
                ok $engine->log_deploy_change($change),
                    "Log internal $desc change deployment";
                is $engine->change_id_for_depend($dep), $change->id,
                    "Internal $desc depencency should now be satisfied";

                # Revert it and try again.
                sleep 0.1; # Give SQLite a little time to tick microseconds.
                ok $engine->log_revert_change($change),
                    "Log internal $desc change reversion";
                is $engine->change_id_for_depend($dep), undef,
                    "Internal $desc depencency should again be unsatisfied";
            }

            # Now test as an external dependency.
            EXTERNAL: {
                # Make sure we have unique IDs.
                $_->{id} = 'dcb10d16276c9be8956274740d9f332bd71344ed'
                    for grep { $_->{id} } $dep_params, $chg_params;

                # Make Change and Tag return registered external project "groovy".
                $dep_params->{project} = 'groovy';
                my $line_mocker = Test::MockModule->new('App::Sqitch::Plan::Line');
                $line_mocker->mock(project => $dep_params->{project});

                ok my $change = App::Sqitch::Plan::Change->new(
                    plan    => $plan,
                    name    => 'foo' . ++$i,
                    %{$chg_params},
                ), "Create external $desc change";

                # Tag it if necessary.
                if (my $tag = $dep_params->{tag}) {
                    ok $change->add_tag(App::Sqitch::Plan::Tag->new(
                        plan    => $plan,
                        change  => $change,
                        name    => $tag,
                    ) ), "Add tag external \@$tag";
                }

                # Should start with unsatisfied dependency.
                ok my $dep = App::Sqitch::Plan::Depend->new(
                    plan    => $plan,
                    project => $plan->project,
                    %{ $dep_params },
                ), "Create external $desc dependency";
                is $engine->change_id_for_depend($dep), undef,
                    "External $desc depencency should not be satisfied";

                # Once deployed, dependency should be satisfied.
                ok $engine->log_deploy_change($change),
                    "Log external $desc change deployment";

                is $engine->change_id_for_depend($dep), $change->id,
                    "External $desc depencency should now be satisfied";

                # Revert it and try again.
                sleep 0.1; # Give SQLite a little time to tick microseconds.
                ok $engine->log_revert_change($change),
                    "Log external $desc change reversion";
                is $engine->change_id_for_depend($dep), undef,
                    "External $desc depencency should again be unsatisfied";
            }
        }

        ok my $ext_change2 = App::Sqitch::Plan::Change->new(
            plan => $ext_plan,
            name => 'outside_in',
        ), "Create another external change";
        ok $ext_change2->add_tag( my $ext_tag = App::Sqitch::Plan::Tag->new(
            plan    => $plan,
            change  => $ext_change2,
            name    => 'meta',
        ) ), 'Add tag external "meta"';

        ok $engine->log_deploy_change($ext_change2), 'Log the external change with tag';

        # Make sure name_for_change_id() works properly.
        ok $engine->dbh->do(q{DELETE FROM tags WHERE project = 'engine'}),
            'Delete the engine project tags';
        is $engine->name_for_change_id($change2->id), 'widgets@HEAD',
            'name_for_change_id() should return "widgets@HEAD" for its ID';
        is $engine->name_for_change_id($ext_change2->id), 'outside_in@meta',
            'name_for_change_id() should return "outside_in@meta" for its ID';

        # Make sure current_changes and current_tags are project-scoped.
        is_deeply all( $engine->current_changes ), \@current_changes,
            'Should have only the "engine" changes from current_changes';
        is_deeply all( $engine->current_changes('groovy') ), [
            {
                change_id       => $ext_change2->id,
                script_hash     => $ext_change2->script_hash,
                change          => $ext_change2->name,
                committer_name  => $user2_name,
                committer_email => $user2_email,
                committed_at    => dt_for_change( $engine, $ext_change2->id ),
                planner_name    => $ext_change2->planner_name,
                planner_email   => $ext_change2->planner_email,
                planned_at      => $ext_change2->timestamp,
            }, {
                change_id       => $ext_change->id,
                script_hash     => $ext_change->script_hash,
                change          => $ext_change->name,
                committer_name  => $user2_name,
                committer_email => $user2_email,
                committed_at    => dt_for_change( $engine, $ext_change->id ),
                planner_name    => $ext_change->planner_name,
                planner_email   => $ext_change->planner_email,
                planned_at      => $ext_change->timestamp,
            }
        ], 'Should get only requestd project changes from current_changes';
        is_deeply all( $engine->current_tags ), [],
            'Should no longer have "engine" project tags';
        is_deeply all( $engine->current_tags('groovy') ), [{
            tag_id          => $ext_tag->id,
            tag             => '@meta',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_tag( $engine, $ext_tag->id ),
            planner_name    => $ext_tag->planner_name,
            planner_email   => $ext_tag->planner_email,
            planned_at      => $ext_tag->timestamp,
        }], 'Should get groovy tags from current_chages()';

        ######################################################################
        # Test changes with multiple and cross-project dependencies.
        ok my $hyper = $plan->add(
            name     => 'hypercritical',
            requires => ['engine:fred', 'groovy:crazyman'],
        ), 'Create change "hypercritial" in current plan';
        $_->resolved_id( $engine->change_id_for_depend($_) ) for $hyper->requires;
        ok $engine->log_deploy_change($hyper), 'Log change "hyper"';

        is_deeply [ $engine->changes_requiring_change($hyper) ], [],
            'No changes should require "hypercritical"';
        is_deeply [ $engine->changes_requiring_change($fred) ], [{
            project   => 'engine',
            change_id => $hyper->id,
            change    => $hyper->name,
            asof_tag  => undef,
        }], 'Change "hypercritical" should require "fred"';

        is_deeply [ $engine->changes_requiring_change($ext_change) ], [{
            project   => 'engine',
            change_id => $hyper->id,
            change    => $hyper->name,
            asof_tag  => undef,
        }], 'Change "hypercritical" should require "groovy:crazyman"';

        # Add another change with more depencencies.
        ok my $ext_change3 = App::Sqitch::Plan::Change->new(
            plan => $ext_plan,
            name => 'elsewise',
            requires => [
                App::Sqitch::Plan::Depend->new(
                    plan    => $ext_plan,
                    project => 'engine',
                    change  => 'fred',
                ),
                App::Sqitch::Plan::Depend->new(
                    plan    => $ext_plan,
                    change  => 'crazyman',
                ),
            ]
        ), "Create a third external change";
        $_->resolved_id( $engine->change_id_for_depend($_) ) for $ext_change3->requires;
        ok $engine->log_deploy_change($ext_change3), 'Log change "elsewise"';

        is_deeply [
            sort { $b->{change} cmp $a->{change} }
            $engine->changes_requiring_change($fred)
        ], [
            {
                project   => 'engine',
                change_id => $hyper->id,
                change    => $hyper->name,
                asof_tag  => undef,
            },
            {
                project   => 'groovy',
                change_id => $ext_change3->id,
                change    => $ext_change3->name,
                asof_tag  => undef,
            },
        ], 'Change "fred" should be required by changes in two projects';

        is_deeply [
            sort { $b->{change} cmp $a->{change} }
            $engine->changes_requiring_change($ext_change)
        ], [
            {
                project   => 'engine',
                change_id => $hyper->id,
                change    => $hyper->name,
                asof_tag  => undef,
            },
            {
                project   => 'groovy',
                change_id => $ext_change3->id,
                change    => $ext_change3->name,
                asof_tag  => undef,
            },
        ], 'Change "groovy:crazyman" should be required by changes in two projects';

        ######################################################################
        # Test begin_work() and finish_work().
        can_ok $engine, qw(begin_work finish_work);
        my $mock_dbh = Test::MockModule->new(ref $engine->dbh, no_auto => 1);
        my $txn;
        $mock_dbh->mock(begin_work => sub { $txn = 1 });
        $mock_dbh->mock(commit     => sub { $txn = 0  });
        $mock_dbh->mock(rollback   => sub { $txn = -1 });
        my @do;
        $mock_dbh->mock(do => sub {
            shift;
            @do = @_;
        });
        ok $engine->begin_work, 'Begin work';
        is $txn, 1, 'Should have started a transaction';
        ok $engine->finish_work, 'Finish work';
        is $txn, 0, 'Should have committed a transaction';
        ok $engine->begin_work, 'Begin work again';
        is $txn, 1, 'Should have started another transaction';
        ok $engine->rollback_work, 'Rollback work';
        is $txn, -1, 'Should have rolled back a transaction';
        $mock_dbh->unmock('do');

        ######################################################################
        # Revert and re-deploy all the changes.
        my @all_changes  = ($change, $change2, $fred, $barney, $ext_change, $ext_change2, $hyper, $ext_change3);
        ok $engine->log_revert_change($_),
            'Revert "' . $_->name . '" change' for reverse @all_changes;
        ok $engine->log_deploy_change($_),
            'Deploy "' . $_->name . '" change' for @all_changes;

        ######################################################################
        # Add a reworked change.
        ok my $rev_change = $plan->rework( name => 'users' ), 'Rework change "users"';
        my $deploy_file = $rev_change->deploy_file;
        my $tmp_dir = dir( tempdir CLEANUP => 1 );
        $deploy_file->copy_to($tmp_dir);
        my $fh = $deploy_file->opena or die "Cannot open $deploy_file: $!\n";
        try {
            say $fh '-- Append line to reworked script so it gets a new SHA-1 hash';
            close $fh;
            $_->resolved_id( $engine->change_id_for_depend($_) ) for $rev_change->requires;
            ok $engine->log_deploy_change($rev_change),  'Deploy the reworked change';
        } finally {
            # Restore the reworked script.
            $tmp_dir->file( $deploy_file->basename )->copy_to($deploy_file);
        };

        # Make sure that change_id_for() chokes on the dupe.
        MOCKVENT: {
            my $sqitch_mocker = Test::MockModule->new(ref $sqitch);
            my @args;
            $sqitch_mocker->mock(vent => sub { shift; push @args => \@_ });
            throws_ok { $engine->change_id_for( change => 'users') } 'App::Sqitch::X',
                'Should die on ambiguous change spec';
            is $@->ident, 'engine', 'Mode should be "engine"';
            is $@->message, __ 'Change Lookup Failed',
                'And it should report change lookup failure';
            is_deeply \@args, [
                [__x(
                    'Change "{change}" is ambiguous. Please specify a tag-qualified change:',
                    change => 'users',
                )],
                [ '  * ', $rev_change->format_name . '@HEAD' ],
                [ '  * ', $change->format_tag_qualified_name ],
            ], 'Should have vented output for lookup failure';

            # But it should work okay if we ask for the first ID.
            ok my $id = $engine->change_id_for(change => 'users', first => 1),
                'Should get ID for first of ambiguous change spec';
            is $id, $change->id, 'Should now have first change id';
        }

        is $engine->change_id_for( change => 'users', tag => 'alpha'), $change->id,
            'change_id_for() should find the tag-qualified change ID';
        is $engine->change_id_for( change => 'users', tag => 'HEAD'), $rev_change->id,
            'change_id_for() should find the reworked change ID @HEAD';

        ######################################################################
        # Tag and Rework the change again.
        ok $plan->tag(name => 'theta'), 'Tag the plan "theta"';
        ok $engine->log_new_tags($rev_change), 'Log new tag';

        ok my $rev_change2 = $plan->rework( name => 'users' ),
            'Rework change "users" again';
        $fh = $deploy_file->opena or die "Cannot open $deploy_file: $!\n";
        try {
            say $fh '-- Append another line to reworked script for a new SHA-1 hash';
            close $fh;
            $_->resolved_id( $engine->change_id_for_depend($_) ) for $rev_change2->requires;
            ok $engine->log_deploy_change($rev_change2),  'Deploy the reworked change';
        } finally {
            # Restore the reworked script.
            $tmp_dir->file( $deploy_file->basename )->copy_to($deploy_file);
        };

        # make sure that change_id_for is still good with things.
        for my $spec (
            [
                'alpha instance of change',
                { change => 'users', tag => 'alpha' },
                $change->id,
            ],
            [
                'HEAD instance of change',
                { change => 'users', tag => 'HEAD' },
                $rev_change2->id,
            ],
            [
                'second instance of change by tag',
                { change => 'users', tag => 'theta' },
                $rev_change->id,
            ],
        ) {
            my ( $desc, $params, $exp_id ) = @{ $spec };
            is $engine->change_id_for(%{ $params }), $exp_id, "Should find id for $desc";
        }

        # Unmock everything and call it a day.
        $mock_dbh->unmock_all;
        $mock_sqitch->unmock_all;

        ######################################################################
        # Let's make sure script_hash upgrades work.
        $engine->dbh->do('UPDATE changes SET script_hash = change_id');
        ok $engine->_update_script_hashes, 'Update script hashes';

        # Make sure they were updated properly.
        my $sth = $engine->dbh->prepare(
            'SELECT change_id, script_hash FROM changes WHERE project = ?',
        );
        $sth->execute($plan->project);
        while (my $row = $sth->fetch) {
            my $change = $plan->get($row->[0]);
            is $row->[1], $change->script_hash,
                'Should have updated script hash for ' . $change->name;
        }

        # Make sure no other projects were updated.
        $sth = $engine->dbh->prepare(
            'SELECT change_id, script_hash FROM changes WHERE project <> ?',
        );
        $sth->execute($plan->project);
        while (my $row = $sth->fetch) {
            is $row->[1], $row->[0],
                'Change ID and script hash should be ' . substr $row->[0], 0, 6;
        }

        ######################################################################
        # Test try_lock() and wait_lock().
        if (my $sql = ($p{lock_sql} || sub {})->($engine)) {
            ok !$engine->dbh->selectcol_arrayref($sql->{is_locked})->[0],
                'Should not be locked';
            ok $engine->try_lock, 'Try lock';
            ok $engine->dbh->selectcol_arrayref($sql->{is_locked})->[0],
                'Should be locked';
            ok $engine->wait_lock, 'Should not have to wait for lock';

            # Make a second connection to the database.
            my $dbh = DBI->connect($engine->uri->dbi_dsn, $engine->username, $engine->password, {
                PrintError        => 0,
                RaiseError        => 1,
                AutoCommit        => 1,
            });
            ok !$dbh->selectcol_arrayref($sql->{try_lock})->[0],
                'Should fail to get same lock in second connection';

            lives_ok { $engine->dbh->do($sql->{free_lock}) } 'Free the lock';
            # Wait for the free to complete if frees are async.
            if (my $wait = $sql->{async_free}) {
                while ($wait) {
                    $wait = $engine->dbh->selectcol_arrayref($sql->{free_lock})->[0];
                }
            }

            ok !$engine->dbh->selectcol_arrayref($sql->{is_locked})->[0],
                'Should not be locked';
            ok $dbh->selectcol_arrayref($sql->{try_lock})->[0],
                'Should now get the lock in second connection';
            ok $engine->dbh->selectcol_arrayref($sql->{is_locked})->[0],
                'Should be locked';
            ok !$engine->try_lock, 'Try lock should now return false';

            # Make sure that wait_lock waits.
            my $secs = $sql->{wait_time} || 0.005;
            $engine->lock_timeout($secs);
            my $time = [gettimeofday];
            ok !$engine->wait_lock, 'Should wait and fail to get the lock';
            cmp_ok tv_interval($time), '>=', $secs, 'Should have waited for the lock';
            lives_ok { $dbh->do($sql->{free_lock}) } 'Free the second lock';

            # Wait for the free to complete if frees are async.
            if (my $wait = $sql->{async_free}) {
                while ($wait) {
                    $wait = $engine->dbh->selectcol_arrayref($sql->{free_lock})->[0];
                }
            }

            # Now wait lock should acquire the lock.
            ok $engine->wait_lock, 'Should no longer wait for lock';
            ok $engine->dbh->selectcol_arrayref($sql->{is_locked})->[0],
                'Should be locked';
            lives_ok { $dbh->do($sql->{free_lock}) } 'Free the lock one last time';
        }

        ######################################################################
        # All done.
        done_testing;
    };
}

sub dt_for_change {
    my $engine = shift;
    my $col = sprintf $engine->_ts2char_format, 'committed_at';
    my $dtfunc = $engine->can('_dt');
    $dtfunc->($engine->dbh->selectcol_arrayref(
        "SELECT $col FROM changes WHERE change_id = ?",
        undef, shift
    )->[0]);
}

sub dt_for_tag {
    my $engine = shift;
    my $col = sprintf $engine->_ts2char_format, 'committed_at';
    my $dtfunc = $engine->can('_dt');
    $dtfunc->($engine->dbh->selectcol_arrayref(
        "SELECT $col FROM tags WHERE tag_id = ?",
        undef, shift
    )->[0]);
}

sub all {
    my $iter = shift;
    my @res;
    while (my $row = $iter->()) {
        push @res => $row;
    }
    return \@res;
}

sub dt_for_event {
    my ($engine, $offset) = @_;
    my $col = sprintf $engine->_ts2char_format, 'committed_at';
    my $dtfunc = $engine->can('_dt');
    my $dbh = $engine->dbh;
    return $dtfunc->($engine->dbh->selectcol_arrayref(qq{
        SELECT ts FROM (
            SELECT ts, rownum AS rnum FROM (
                SELECT $col AS ts
                  FROM events
                 ORDER BY committed_at ASC
            )
        ) WHERE rnum = ?
    }, undef, $offset + 1)->[0]) if $dbh->{Driver}->{Name} eq 'Oracle';
    return $dtfunc->($engine->dbh->selectcol_arrayref(
        "SELECT FIRST 1 SKIP $offset $col FROM events ORDER BY committed_at ASC",
    )->[0]) if $dbh->{Driver}->{Name} eq 'Firebird';
    return $dtfunc->($engine->dbh->selectcol_arrayref(
        "SELECT $col FROM events ORDER BY committed_at ASC LIMIT 1 OFFSET $offset",
    )->[0]);
}

sub all_changes {
    shift->dbh->selectall_arrayref(q{
        SELECT change_id, c.change, project, note, committer_name, committer_email,
               planner_name, planner_email
          FROM changes c
         ORDER BY committed_at
    });
}

sub all_tags {
    shift->dbh->selectall_arrayref(q{
        SELECT tag_id, tag, change_id, project, note,
               committer_name, committer_email, planner_name, planner_email
          FROM tags
         ORDER BY committed_at
    });
}

sub all_events {
    shift->dbh->selectall_arrayref(q{
        SELECT event, change_id, e.change, project, note, requires, conflicts, tags,
               committer_name, committer_email, planner_name, planner_email
          FROM events e
         ORDER BY committed_at
    });
}

sub get_dependencies {
    shift->dbh->selectall_arrayref(q{
        SELECT change_id, type, dependency, dependency_id
          FROM dependencies
         WHERE change_id = ?
         ORDER BY dependency
    }, undef, shift);
}

1;
