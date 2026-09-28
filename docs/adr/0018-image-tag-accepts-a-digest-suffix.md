---
status: accepted
---

# `image.tag` accepts a `@<digest>` suffix

Since 3.0.0 (issue #173) `image.tag` holds an OCI tag and nothing else. Argo CD
Image Updater breaks that rule. With the `digest` strategy and Helm write-back,
it writes `<tag>@<digest>` into the tag key (`GetTagWithDigest()`). Its Helm
target has a key for the name and one for the tag, and none for the digest.
The values file belongs to the bot, and the next poll rewrites it in the same
shape. A schema that rejects the value therefore leaves the Application in
`ComparisonError` for good, and the user cannot fix it (issue #187).
`image.tag` now accepts an optional `@<digest>` suffix, with the digest grammar
of `image.digest`. The value renders as written: `repo:<tag>@<digest>`, a valid
OCI reference.

## Decisions

**A non-empty tag before the `@`.** A tag made only of `@sha256:…` would render
`repo:@sha256:…`, the `InvalidImageName` that #173 removed. A digest on its own
already has its field. Image Updater always writes a tag before the digest. The
schema's tag pattern rejects it, and `imageString` does too, as the backstop
under `--skip-schema-validation` (ADR 0017), like the pair below.

**A digest in `tag` together with `image.digest` fails, even when the two are
equal.** The rule "`digest` wins over `tag`" would render `repo@<image.digest>`
and drop the bot's digest in silence. The pin in the values would then no
longer be the pin in the pod, and each new poll would change nothing. Two
sources for one pin are a configuration error, and the equality would not
survive the next poll. The schema rejects the pair. `imageString` rejects it
too, as a backstop guard for `--skip-schema-validation` (ADR 0017), since every
scope passes through that helper.

**A plain `tag` with `image.digest` still lets the digest win.** The asymmetry
is intended. Dropping a tag that carries no pin loses nothing, but dropping a
digest loses the pin. Making the two rules uniform would change the output of
values that are valid today, so it is not a patch-level change.

## Considered Options

- **Split the value into `tag` + `digest` in the template.** Rejected: the
  field would mean one thing in the values and another in the manifest, for
  no gain. The rendered reference is already valid.
- **Ask the writer to split it.** Not possible: Image Updater's Helm target
  has no digest key.
