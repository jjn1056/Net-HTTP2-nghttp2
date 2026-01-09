# Alien::nghttp2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create Alien::nghttp2 to automate nghttp2 library installation for CPAN users.

**Architecture:** Use Alien::Build framework with PkgConfig plugin for system detection, CMake plugin for source builds. Library-only build (ENABLE_LIB_ONLY=ON) to minimize dependencies.

**Tech Stack:** Alien::Build, Alien::Build::Plugin::Build::CMake, pkg-config, CMake 3.14+

---

## Prerequisites

Before starting, ensure these are installed:
```bash
cpanm Alien::Build Alien::Build::Plugin::Build::CMake
brew install cmake pkg-config  # macOS
```

---

## Task 1: Create Distribution Structure

**Files:**
- Create: `~/Desktop/Alien-nghttp2/` (new directory)
- Create: `~/Desktop/Alien-nghttp2/lib/Alien/nghttp2.pm`
- Create: `~/Desktop/Alien-nghttp2/alienfile`
- Create: `~/Desktop/Alien-nghttp2/Makefile.PL`
- Create: `~/Desktop/Alien-nghttp2/t/00-load.t`

**Step 1: Create directory structure**

```bash
mkdir -p ~/Desktop/Alien-nghttp2/lib/Alien
mkdir -p ~/Desktop/Alien-nghttp2/t
cd ~/Desktop/Alien-nghttp2
git init
```

**Step 2: Create .gitignore**

Create `~/Desktop/Alien-nghttp2/.gitignore`:
```
/blib/
/Makefile
/Makefile.old
/MYMETA.*
/pm_to_blib
/_alien/
/.alien/
/Alien-nghttp2-*
*.o
*.bs
*.c
```

**Step 3: Commit**

```bash
git add .gitignore
git commit -m "Initial commit: .gitignore"
```

---

## Task 2: Create the alienfile

**Files:**
- Create: `~/Desktop/Alien-nghttp2/alienfile`

**Step 1: Write the alienfile**

Create `~/Desktop/Alien-nghttp2/alienfile`:
```perl
use alienfile;

plugin 'PkgConfig' => 'libnghttp2';

share {
    requires 'Alien::Build::Plugin::Build::CMake' => '0.99';
    requires 'Alien::cmake3' => '0.02';

    plugin 'Download' => (
        url     => 'https://github.com/nghttp2/nghttp2/releases',
        version => qr/nghttp2-([\d\.]+)\.tar\.gz$/,
        filter  => qr/\.tar\.gz$/,
    );

    plugin 'Extract' => 'tar.gz';

    plugin 'Build::CMake' => ();

    build [
        ['%{cmake}',
            @{ meta->prop->{plugin_build_cmake}->{args} },
            '-DENABLE_LIB_ONLY=ON',
            '-DENABLE_STATIC_LIB=OFF',
            '-DCMAKE_INSTALL_PREFIX:PATH=%{.install.prefix}',
            '%{.install.extract}',
        ],
        ['%{make}'],
        ['%{make}', 'install'],
    ];
};
```

**Step 2: Verify syntax**

```bash
perl -c alienfile
```
Expected: `alienfile syntax OK`

**Step 3: Commit**

```bash
git add alienfile
git commit -m "Add alienfile for nghttp2 build recipe"
```

---

## Task 3: Create the Main Module

**Files:**
- Create: `~/Desktop/Alien-nghttp2/lib/Alien/nghttp2.pm`

**Step 1: Write the module**

Create `~/Desktop/Alien-nghttp2/lib/Alien/nghttp2.pm`:
```perl
package Alien::nghttp2;

use strict;
use warnings;
use base qw(Alien::Base);

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Alien::nghttp2 - Find or build the nghttp2 HTTP/2 C library

=head1 SYNOPSIS

    use Alien::nghttp2;
    use ExtUtils::MakeMaker;

    WriteMakefile(
        ...
        CONFIGURE_REQUIRES => {
            'Alien::nghttp2' => '0',
        },
        LIBS   => [ Alien::nghttp2->libs ],
        CCFLAGS => Alien::nghttp2->cflags,
    );

Or with L<Alien::Build::MM>:

    use Alien::Build::MM;
    my $abmm = Alien::Build::MM->new;

    WriteMakefile($abmm->mm_args(
        ...
        BUILD_REQUIRES => {
            'Alien::nghttp2' => '0',
        },
    ));

=head1 DESCRIPTION

This L<Alien> module provides the nghttp2 HTTP/2 C library. It will
either detect the library installed on your system, or download and
build it from source.

nghttp2 is an implementation of the HTTP/2 protocol (RFC 9113) and
HPACK header compression (RFC 7541), used by curl, Apache httpd,
Firefox, and many other projects.

=head1 METHODS

All methods are inherited from L<Alien::Base>:

=head2 cflags

    my $cflags = Alien::nghttp2->cflags;

Returns compiler flags needed to compile against nghttp2.

=head2 libs

    my $libs = Alien::nghttp2->libs;

Returns linker flags needed to link against nghttp2.

=head2 dynamic_libs

    my @libs = Alien::nghttp2->dynamic_libs;

Returns list of dynamic library paths.

=head2 install_type

    my $type = Alien::nghttp2->install_type;

Returns 'system' or 'share' depending on how nghttp2 was installed.

=head1 SEE ALSO

L<Alien::Base>, L<Alien::Build>, L<Net::HTTP2::nghttp2>

L<https://nghttp2.org/> - nghttp2 project homepage

=head1 AUTHOR

Your Name <your@email.com>

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
```

**Step 2: Verify syntax**

```bash
perl -Ilib -c lib/Alien/nghttp2.pm
```
Expected: `lib/Alien/nghttp2.pm syntax OK`

**Step 3: Commit**

```bash
git add lib/Alien/nghttp2.pm
git commit -m "Add Alien::nghttp2 module"
```

---

## Task 4: Create Makefile.PL

**Files:**
- Create: `~/Desktop/Alien-nghttp2/Makefile.PL`

**Step 1: Write Makefile.PL**

Create `~/Desktop/Alien-nghttp2/Makefile.PL`:
```perl
use strict;
use warnings;
use ExtUtils::MakeMaker;
use Alien::Build::MM;

my $abmm = Alien::Build::MM->new;

WriteMakefile($abmm->mm_args(
    NAME               => 'Alien::nghttp2',
    VERSION_FROM       => 'lib/Alien/nghttp2.pm',
    ABSTRACT_FROM      => 'lib/Alien/nghttp2.pm',
    AUTHOR             => 'Your Name <your@email.com>',
    LICENSE            => 'perl_5',
    MIN_PERL_VERSION   => '5.016',
    CONFIGURE_REQUIRES => {
        'Alien::Build::MM' => '0.32',
        'Alien::Build'     => '2.37',
        'ExtUtils::MakeMaker' => '6.52',
    },
    BUILD_REQUIRES => {
        'Alien::Build' => '2.37',
        'Alien::Build::Plugin::Build::CMake' => '0.99',
    },
    TEST_REQUIRES => {
        'Test::More' => '0.96',
        'Test::Alien' => '0',
    },
    PREREQ_PM => {
        'Alien::Base' => '2.37',
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/yourname/Alien-nghttp2.git',
                web  => 'https://github.com/yourname/Alien-nghttp2',
            },
            bugtracker => {
                web => 'https://github.com/yourname/Alien-nghttp2/issues',
            },
        },
    },
));

sub MY::postamble {
    $abmm->mm_postamble;
}
```

**Step 2: Verify syntax**

```bash
perl -c Makefile.PL
```
Expected: `Makefile.PL syntax OK`

**Step 3: Commit**

```bash
git add Makefile.PL
git commit -m "Add Makefile.PL with Alien::Build::MM"
```

---

## Task 5: Create Basic Test

**Files:**
- Create: `~/Desktop/Alien-nghttp2/t/00-load.t`

**Step 1: Write the test**

Create `~/Desktop/Alien-nghttp2/t/00-load.t`:
```perl
use strict;
use warnings;
use Test::More tests => 4;

BEGIN { use_ok('Alien::nghttp2') }

diag "Alien::nghttp2 version: " . Alien::nghttp2->VERSION;
diag "Install type: " . Alien::nghttp2->install_type;
diag "cflags: " . Alien::nghttp2->cflags;
diag "libs: " . Alien::nghttp2->libs;

ok(Alien::nghttp2->cflags =~ /nghttp2/ || Alien::nghttp2->install_type eq 'system',
   'cflags contains nghttp2 or is system install');

ok(Alien::nghttp2->libs =~ /nghttp2/,
   'libs contains nghttp2');

like(Alien::nghttp2->install_type, qr/^(system|share)$/,
   'install_type is system or share');
```

**Step 2: Commit**

```bash
git add t/00-load.t
git commit -m "Add basic load test"
```

---

## Task 6: Create Test::Alien Test

**Files:**
- Create: `~/Desktop/Alien-nghttp2/t/01-alien.t`

**Step 1: Write Test::Alien test**

Create `~/Desktop/Alien-nghttp2/t/01-alien.t`:
```perl
use strict;
use warnings;
use Test::More;
use Test::Alien;

BEGIN { plan skip_all => 'Test::Alien required' unless eval { require Test::Alien; 1 } }

plan tests => 3;

use Alien::nghttp2;

alien_ok 'Alien::nghttp2';

my $xs = do { local $/; <DATA> };
xs_ok $xs, with_subtest {
    my ($module) = @_;
    my $version = $module->version();
    ok $version, "nghttp2 version: $version";
    diag "nghttp2 library version: $version";
};

__DATA__
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <nghttp2/nghttp2.h>

MODULE = TA_nghttp2 PACKAGE = TA_nghttp2

const char *
version()
    CODE:
        nghttp2_info *info = nghttp2_version(0);
        RETVAL = info->version_str;
    OUTPUT:
        RETVAL
```

**Step 2: Commit**

```bash
git add t/01-alien.t
git commit -m "Add Test::Alien XS compilation test"
```

---

## Task 7: Build and Test with System Library

**Step 1: Ensure nghttp2 is installed on system**

```bash
# macOS
brew install nghttp2

# Or verify it's installed
pkg-config --modversion libnghttp2
```
Expected: Version number like `1.66.0`

**Step 2: Build the Alien**

```bash
cd ~/Desktop/Alien-nghttp2
perl Makefile.PL
make
```
Expected: Build completes, shows "system" install type

**Step 3: Run tests**

```bash
make test
```
Expected: All tests pass

**Step 4: Commit any fixes**

```bash
git status
# Commit any necessary fixes
```

---

## Task 8: Test Share Install (Build from Source)

**Step 1: Force share install**

```bash
cd ~/Desktop/Alien-nghttp2
make clean
ALIEN_INSTALL_TYPE=share perl Makefile.PL
```
Expected: Shows downloading/building from source

**Step 2: Build from source**

```bash
make
```
Expected: CMake build completes (takes 1-2 minutes)

**Step 3: Run tests**

```bash
make test
```
Expected: All tests pass with "share" install type

**Step 4: Clean up**

```bash
make clean
```

---

## Task 9: Create CLAUDE.md

**Files:**
- Create: `~/Desktop/Alien-nghttp2/CLAUDE.md`

**Step 1: Write CLAUDE.md**

Create `~/Desktop/Alien-nghttp2/CLAUDE.md`:
```markdown
# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

Alien::nghttp2 provides the nghttp2 HTTP/2 C library for CPAN. It uses
Alien::Build to either detect the system library or build from source.

## Build Commands

```bash
# Build with system library (default)
perl Makefile.PL
make
make test

# Force build from source
ALIEN_INSTALL_TYPE=share perl Makefile.PL
make
make test

# Clean
make clean
make realclean
```

## Key Files

| File | Purpose |
|------|---------|
| `alienfile` | Build recipe (system detection + source build) |
| `lib/Alien/nghttp2.pm` | Main module (inherits Alien::Base) |
| `Makefile.PL` | Build script using Alien::Build::MM |
| `t/00-load.t` | Basic loading test |
| `t/01-alien.t` | Test::Alien XS compilation test |

## Environment Variables

- `ALIEN_INSTALL_TYPE=system` - Only use system library, fail if not found
- `ALIEN_INSTALL_TYPE=share` - Always build from source
- (unset) - Try system first, fall back to source build
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Add CLAUDE.md"
```

---

## Task 10: Update Net-HTTP2-nghttp2 to Use Alien

**Files:**
- Modify: `~/Desktop/Net-HTTP2-nghttp2/Makefile.PL`

**Step 1: Read current Makefile.PL**

```bash
cat ~/Desktop/Net-HTTP2-nghttp2/Makefile.PL
```

**Step 2: Update to support Alien::nghttp2**

The Makefile.PL should try:
1. pkg-config (current behavior)
2. Alien::nghttp2 if pkg-config fails

Add this logic after the existing pkg-config detection:

```perl
# After existing detection fails, try Alien::nghttp2
if (!$cflags && !$libs) {
    eval { require Alien::nghttp2; 1 } and do {
        $cflags = Alien::nghttp2->cflags;
        $libs   = Alien::nghttp2->libs;
        print "Found nghttp2 via Alien::nghttp2:\n";
        print "  CFLAGS: $cflags\n";
        print "  LIBS:   $libs\n";
    };
}
```

**Step 3: Add Alien::nghttp2 as optional dependency**

In META_MERGE or PREREQ_PM:
```perl
CONFIGURE_REQUIRES => {
    # ... existing ...
    'Alien::nghttp2' => '0',  # Optional, for systems without pkg-config
},
```

**Step 4: Test the integration**

```bash
cd ~/Desktop/Net-HTTP2-nghttp2
perl Makefile.PL
make
make test
```

**Step 5: Commit**

```bash
git add Makefile.PL
git commit -m "Add Alien::nghttp2 fallback for library detection"
```

---

## Task 11: Final Testing and Documentation

**Step 1: Test complete workflow on clean system (optional)**

```bash
# Uninstall system nghttp2 temporarily
brew uninstall nghttp2

# Install via Alien
cd ~/Desktop/Alien-nghttp2
perl Makefile.PL
make
make install

# Build Net-HTTP2-nghttp2
cd ~/Desktop/Net-HTTP2-nghttp2
perl Makefile.PL
make
make test

# Reinstall system nghttp2
brew install nghttp2
```

**Step 2: Update Net-HTTP2-nghttp2 POD**

Add to SEE ALSO section:
```pod
L<Alien::nghttp2> - Alien module for automatic nghttp2 installation
```

**Step 3: Final commits**

```bash
cd ~/Desktop/Alien-nghttp2
git log --oneline  # Verify all commits

cd ~/Desktop/Net-HTTP2-nghttp2
git add -A
git commit -m "Document Alien::nghttp2 in POD"
```

---

## Summary

After completing all tasks you will have:

1. **Alien::nghttp2** - Standalone CPAN distribution that:
   - Detects system nghttp2 via pkg-config
   - Builds nghttp2 from source if needed
   - Provides cflags/libs for dependent modules

2. **Net-HTTP2-nghttp2** - Updated to:
   - Use Alien::nghttp2 as fallback
   - Work on systems without pkg-config
   - Fully automated installation via `cpanm Net::HTTP2::nghttp2`

## Estimated Time

- Tasks 1-6: ~30 minutes (boilerplate)
- Tasks 7-8: ~15 minutes (testing)
- Tasks 9-11: ~15 minutes (integration)
- **Total: ~1 hour**
