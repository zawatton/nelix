# Nelix registry

A static Nelix package registry: `index.el` and the recipe files it names.
Generated from [zawatton/nelix](https://github.com/zawatton/nelix) by `make pages`.

```elisp
(setq nelix-registry-remotes
      '((:name "zawatton"
         :url "https://zawatton.github.io/nelix/index.el"
         :sha256 "sha256-...")))   ; the hash `make pages` printed

(nelix-registry-update)
```

Two hashes are checked: you pin the index, and the index pins every recipe it
names. A changed byte anywhere is refused rather than installed.

This index is unsigned, so the pinned hash is how you know what you are
getting. When a new index is published the hash changes and you update
`:sha256` to match. Nothing here is fetched without being verified against a
hash you or the index declared.

Do not edit this branch by hand: it is regenerated wholesale by `make pages`.
