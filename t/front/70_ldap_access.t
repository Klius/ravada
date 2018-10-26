use warnings;
use strict;

use Data::Dumper;
use Hash::Util qw(lock_hash);
use Test::More;

no warnings "experimental::signatures";
use feature qw(signatures);

use lib 't/lib';
use Test::Ravada;

use Ravada::Auth::LDAP;
my $CONFIG_FILE = 't/etc/ravada_ldap.conf';

init( $CONFIG_FILE );
delete $Ravada::CONFIG->{ldap}->{ravada_posix_group};

sub test_external_auth {
    my ($name, $password) = ('jimmy','jameson');
    create_ldap_user($name, $password);
    my $login_ok;
    eval { $login_ok = Ravada::Auth::login($name, $password) };
    is($@, '');
    ok($login_ok,"Expecting login with $name") or return;
    ok($login_ok->ldap_entry,"Expecting a LDAP entry for user $name in object ".ref($login_ok));

    my $user = Ravada::Auth::SQL->new(name => $name);
    is($user->external_auth, 'ldap') or exit;
    ok($user->ldap_entry,"Expecting a LDAP entry for user $name in object ".ref($user));

    my $sth = connector->dbh->prepare(
        "UPDATE users set external_auth = '' "
        ." WHERE id=?"
    );
    $sth->execute($user->id);

    $user = Ravada::Auth::SQL->new(name => $name);
    is($user->external_auth, '') or exit;

    eval { $login_ok = Ravada::Auth::login($name, $password) };
    is($@, '');
    ok($login_ok,"Expecting login with $name") or return;

    $user = Ravada::Auth::SQL->new(name => $name);
    is($user->external_auth, 'ldap') or exit;
}

sub _create_users() {
    my $data = {
        student => { name => 'student', password => 'aaaaaaa' }
        ,teacher => { name => 'teacher', password => 'bbbbbbb' }
    };

    for my $type ( keys %$data) {
        create_ldap_user($data->{$type}->{name}, $data->{$type}->{password});

        my $login_ok;
        eval { $login_ok = Ravada::Auth::login(
                $data->{$type}->{name}
                , $data->{$type}->{password}) 
        };
        is($@, '');
        ok($login_ok,"Expecting login with $data->{$type}->{name}") or return;
        $data->{$type}->{user} = Ravada::Auth::SQL->new(name => $data->{$type}->{name});
    }
    my $other = { name => 'other'.new_domain_name(), password => 'ccccccc' };
    create_user($other->{name}, $other->{password});
    $other->{user} = Ravada::Auth::SQL->new(name => $other->{name});
    $data->{other} = $other;

    ok($data->{other}->{user}->id);
    return $data;
}

sub _refresh_users($data) {
    for my $key (keys %$data) {
        delete $data->{$key}->{user}->{_ldap_entry};
        delete $data->{$key}->{user}->{_load_allowed};
    }
}

sub _do_clones($data, $base, $do_clones) {

    return if !$do_clones;

    my $clone_student = $base->clone(
        name => new_domain_name
        ,user => $data->{student}->{user}
    );
    my $clone_teacher= $base->clone(
        name => new_domain_name
        ,user => $data->{teacher}->{user}
    );

    return ($clone_student, $clone_teacher);
}

sub test_access_by_attribute($vm, $do_clones=0) {

    my $data = _create_users();

    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    _do_clones($data, $base, $do_clones);

    my $list_bases = rvd_front->list_machines_user($data->{student}->{user});
    is(scalar (@$list_bases), 1);

    #################################################################
    #
    #  all should be allowed now
    is($data->{student}->{user}->allowed_access( $base->id ), 1);
    is($data->{teacher}->{user}->allowed_access( $base->id ), 1);
    is($data->{other}->{user}->allowed_access( $base->id ), 1);
    is(user_admin->allowed_access( $base->id ), 1);

    $data->{student}->{user}->ldap_entry->replace( givenName => 'Jimmy');
    my $mesg = $data->{student}->{user}->ldap_entry->update(Ravada::Auth::LDAP::_init_ldap_admin);
    is($mesg->code,0, $mesg->error) or BAIL_OUT();

    _refresh_users($data);

    is($data->{student}->{user}->ldap_entry->get_value('givenName'),'Jimmy') or BAIL_OUT();

    $base->allow_ldap_attribute( givenName => 'Jimmy');

    #################################################################
    #
    #  only students and admin should be allowed
    is($data->{student}->{user}->allowed_access( $base->id ), 1);
    is($data->{teacher}->{user}->allowed_access( $base->id ), 0);
    is(user_admin->allowed_access( $base->id ), 1);

    $list_bases = rvd_front->list_machines_user($data->{student}->{user});
    is(scalar (@$list_bases), 1);

    $list_bases = rvd_front->list_machines_user($data->{teacher}->{user});
    is(scalar (@$list_bases), 0);

    $list_bases = rvd_front->list_machines_user($data->{other}->{user});
    is(scalar (@$list_bases), 1);

    $list_bases = rvd_front->list_machines_user(user_admin);
    is(scalar (@$list_bases), 1);

    _remove_bases($base);
}

sub _create_bases($vm, $n=1) {

    my @bases;
    for (1 .. $n ) {
        my $base = create_domain($vm->type);
        $base->prepare_base(user_admin);
        $base->is_public(1);

        push @bases,($base);
    }

    return @bases;

}

sub _remove_bases(@bases) {
    for my $base (@bases) {
        for my $clone_data ($base->clones) {
            my $clone = Ravada::Domain->open($clone_data->{id});
            $clone->remove(user_admin);
        }
        $base->remove(user_admin);
    }
}

sub test_access_by_attribute_2bases($vm, $do_clones=0) {

    my $data = _create_users();

    my @bases  = _create_bases($vm,2);

    _do_clones($data, $bases[0], $do_clones);
    _do_clones($data, $bases[1], $do_clones);

    my $list_bases = rvd_front->list_machines_user($data->{student}->{user});
    is(scalar (@$list_bases), 2);

    #################################################################
    #
    #  all should be allowed now
    for my $base ( @bases ) {
        is($data->{student}->{user}->allowed_access( $base->id ), 1);
        is($data->{teacher}->{user}->allowed_access( $base->id ), 1);
        is(user_admin->allowed_access( $base->id ), 1);
    }

    $data->{student}->{user}->ldap_entry->replace( givenName => 'Jimmy');
    my $mesg = $data->{student}->{user}->ldap_entry->update(Ravada::Auth::LDAP::_init_ldap_admin);
    is($mesg->code,0, $mesg->error) or BAIL_OUT();

    _refresh_users($data);

    is($data->{student}->{user}->ldap_entry->get_value('givenName'),'Jimmy') or BAIL_OUT();

    $bases[0]->allow_ldap_attribute( givenName => 'Jimmy');

    #################################################################
    #
    #  only students and admin should be allowed
    is($data->{student}->{user}->allowed_access( $bases[0]->id ), 1);
    is($data->{teacher}->{user}->allowed_access( $bases[0]->id ), 0);
    is(user_admin->allowed_access( $bases[0]->id ), 1);

    $list_bases = rvd_front->list_machines_user($data->{student}->{user});
    is(scalar (@$list_bases), 2);

    $list_bases = rvd_front->list_machines_user($data->{teacher}->{user});
    is(scalar (@$list_bases), 1);

    $list_bases = rvd_front->list_machines_user($data->{other}->{user});
    is(scalar (@$list_bases), 1);

    $list_bases = rvd_front->list_machines_user(user_admin);
    is(scalar (@$list_bases), 2);

    _remove_bases(@bases);
}

################################################################################

clean();


for my $vm_name ('KVM', 'Void') {
    my $vm = rvd_back->search_vm($vm_name);

    SKIP: {

        my $msg = "SKIPPED: No virtual managers found";
        if ($vm && $vm_name =~ /kvm/i && $>) {
            $msg = "SKIPPED: Test must run as root";
            $vm = undef;
        }

        skip($msg,10)   if !$vm;
        diag("Testing LDAP access for $vm_name");

        test_external_auth();
        test_access_by_attribute($vm);
        test_access_by_attribute($vm,1); # with clones
    }

}

clean();

done_testing();

