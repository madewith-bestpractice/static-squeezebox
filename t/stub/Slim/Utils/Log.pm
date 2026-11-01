package Slim::Utils::Log; use strict; use Exporter 'import'; our @EXPORT = qw(logger);
sub logger { bless {}, __PACKAGE__ } sub info {} sub warn {} sub error { shift; print STDERR "ERROR: @_\n" }
package main; sub INFOLOG { 0 } 1;
