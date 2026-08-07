# http

A minimal HTTP/1.1 server suitable for embedded use.

This package is stripped to the bare minimum, so you can build on it. It handles the
sockets and the HTTP framing protocol, and nothing else. In particular, the parts of
HTTP semantics that focus on target resources are not provided by this package.

Why? Sometimes it's nice to embed a small server inside an application to communicate
with it from the outside world, and rather than build your own TCP protocol, HTTP gives
you a very simple foundation: verbs, targets, metadata, and data. A full
batteries-included HTTP server is overkill for that use case.

## Features

- Single-threaded operation using [nbio](https://pkg.odin-lang.org/core/nbio/).
- Accepts a shutdown signal for clean shutdown.
- Gracefully handles socket exhaustion (server overload) and slow clients.
- Connection pool to minimise memory allocations. Uses Odin's
  [virtual](https://pkg.odin-lang.org/core/mem/virtual/) memory.
- Decent performance: echo server provides 75,000 req/sec on Linux, 50,000 req/sec on
  Windows. Real workloads will of course have higher latency.

## Overview

Writing an HTTP server on top of sockets is finicky work, even before dealing with
multiple platforms. Luckily, Odin's nbio makes light work of multi-platform support. But
things are still finicky when dealing with sockets. For instance, messages may not
arrive in a single callback, so the protocol parser has to accommodate partial messages
and respond accordingly.

### Some technical details

#### Virtual memory arena

Each connection allocates a virtual memory arena using `mem:virtual/arena_init_growing`
and uses it for receive buffers and processing of the HTTP message and payload. The
growing arena has the nice property that if there is a surge of memory use in a single
connection, the excess committed memory will be returned to the operating system at the
end of the exchange. By contrast, using a static arena would NOT have this property, as
the current implementation of `mem:virtual/arena_free_all` does not decommit.

#### Socket exhaustion

It can happen that an overloaded service runs out of operating system sockets. We handle
that gracefully, using an old trick: we reserve a file descriptor at the start of the
server by opening /dev/null (or NUL on Windows), so we can temporarily release it in
order to allow a client connection that would otherwise have failed, just so we can send
a 503 Service Unavailable back to it.

#### Slow/trickling client

If we receive an incomplete message in the first recv, we use a five second timeout
waiting for the next chunk. If the timeout is triggered and message is still incomplete
after receiving the next chunk, we send back a 408 Request Timeout.

### Limitations

A fully RFC9110/9112 compliant HTTP/1.1 server will need to also implement the full set
of required semantics. For example, the `Content-Location` header has a [special
meaning](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.7-1), etc. Full HTTP
target resource semantics are out of scope for this minimal library, but would be easy
to build on top of it.
