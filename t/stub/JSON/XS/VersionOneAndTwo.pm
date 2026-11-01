package JSON::XS::VersionOneAndTwo; use strict; use JSON::PP (); use Exporter 'import'; our @EXPORT = qw(from_json to_json);
sub from_json { JSON::PP->new->utf8->decode($_[0]) } sub to_json { JSON::PP->new->utf8->encode($_[0]) } 1;
