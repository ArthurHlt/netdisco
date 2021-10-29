package App::Netdisco::Web::Plugin::Device::SNMP;

use strict;
use warnings;

use Dancer ':syntax';
use Dancer::Plugin::Ajax;
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Swagger;
use Dancer::Plugin::Auth::Extensible;

use App::Netdisco::Web::Plugin;
use MIME::Base64 'decode_base64';
use Storable 'thaw';
use Try::Tiny;

register_device_tab({ tag => 'snmp', label => 'SNMP' });

get '/ajax/content/device/snmp' => require_login sub {
    my $q = param('q');

    my $device = schema('netdisco')->resultset('Device')
      ->search_for_device($q) or send_error('Bad device', 400);

    template 'ajax/device/snmp.tt', { device => $device->ip },
      { layout => 'noop' };
};

ajax '/ajax/data/device/:ip/snmptree/:base' => require_login sub {
    my $device = try { schema('netdisco')->resultset('Device')
                                         ->find( param('ip') ) }
       or send_error('Bad Device', 404);

    my $base = param('base');
    $base =~ m/^\.1\.3\.6\.1(\.\d+)*$/ or send_error('Bad OID Base', 404);

    my $items = _get_snmp_data($device->ip, $base);

    content_type 'application/json';
    to_json $items;
};

ajax '/ajax/content/snmpnode/:oid' => require_login sub {
    my $oid = param('oid');
    $oid =~ m/^\.1\.3\.6\.1(\.\d+)*$/ or send_error('Bad OID', 404);

    my $object = schema('netdisco')->resultset('DeviceBrowser')
      ->find({ 'snmp_object.oid' => $oid }, { prefetch => 'snmp_object' })
      or send_error('Bad OID', 404);

    my %data = (
      $object->get_columns,
      snmp_object => { $object->snmp_object->get_columns },
      value => ($object->value ? to_json( @{ thaw( decode_base64( $object->value ) ) } )
                               : undef),
    );

    template 'ajax/device/snmpnode.tt', { node => \%data },
        { layout => 'noop' };
};

sub _get_snmp_data {
    my ($ip, $base) = @_;
    my @parts = grep {length} split m/\./, $base;

    my %kids = map { ($base .'.'. $_->{part}) => $_ }
               schema('netdisco')->resultset('Virtual::OidChildren')
                                 ->search({}, { bind => [
                                     (scalar @parts + 1),
                                     (scalar @parts + 2),
                                     $base,
                                     (scalar @parts + 1),
                                     (scalar @parts + 1),
                                     $ip,
                                     $base,
                                 ] })->hri->all;

    my %meta = map { ('.'. join '.', @{$_->{oid_parts}}) => $_ }
               schema('netdisco')->resultset('Virtual::FilteredSNMPObject')
                                 ->search({}, { bind => [
                                     $base,
                                     (scalar @parts + 1),
                                     [[ map {$_->{part}} values %kids ]],
                                     (scalar @parts + 1),
                                 ] })->hri->all;

    my @items = map {{
        id => $_,
        text => ($meta{$_}->{leaf} .' ('. $kids{$_}->{part} .')'),

        # for nodes with only one child, recurse to prefetch...
        children => ($kids{$_}->{children} == 1 ? _get_snmp_data($ip, ("${base}.". $kids{$_}->{part}))
                                                : ($kids{$_}->{children} ? \1 : \0)),
        # and set the display to open to show the single child
        ($kids{$_}->{children} == 1 ? (state => { opened => \1 }) : ()),

        ($kids{$_}->{children} ? () : (icon => 'icon-leaf')),
        (scalar @{$meta{$_}->{index}} ? (icon => 'icon-th') : ()),
      }} sort {$kids{$a}->{part} <=> $kids{$b}->{part}} keys %kids;

    return \@items;
}

true;
