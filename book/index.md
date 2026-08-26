# UniMedia

A media library that lives in a folder you own.

Your photographs stay where they are, as files, in directories you can read
without this program. What UniMedia adds is a catalogue beside them — one
SQLite file at the root — and a set of operations that never lose anything:
every one shows you what it would do before it does it, and every one that
touches a file keeps what it replaced.

There is no server, no account, no cloud, and nothing that phones anywhere. The
one network call in the whole engine asks a geocoder what a pair of coordinates
is called, and only when you ask it to.

## Who this is for

The manual is in three parts because two readers meet in only one place.

**What a library is** is for everybody. It defines the words the rest uses —
library, item, batch, trash — and shows the database schema. Skip it and the
other parts will use terms you have to guess at.

**Using the tool** is for somebody with photographs to sort. It is a sequence,
not a reference: a folder becomes a library, gets filed by date, searched,
de-duplicated, corrected, cleaned. Every command shown was run to produce the
output beneath it.

**Building on it** is for somebody putting UniMedia inside something else. The
Nim API first because it is the native one, then Python, then the C ABI that
both rest on.

The graphical applications that link this engine are a separate product and
carry their own manual. Everything they do, the `om` command does too — this
book is about the engine and the command line.

## What it will not do

It does not edit photographs. It reads them, moves them, and writes metadata
into them; it never re-encodes an image or a video, so a file that goes through
it comes out with the same pixels.

It does not decide for you. Every destructive operation prints a plan and stops;
`--yes` is what makes it act. The plan is rebuilt inside the apply, so it cannot
act on something you read five minutes ago.

It does not delete quietly. What it removes goes to a trash inside the library
and stays there until you empty it. The one command that truly deletes says so
in the plan, in the confirmation, and in the report.
