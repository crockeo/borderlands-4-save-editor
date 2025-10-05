# Borderlands 4 Save Editor

Implementing the basics of a Borderlands 4 save editor inside of Zig,
because it gives me a good excuse to learn some fun parts of Zig.
Fun reference implementation of:

- Integrating OpenSSL <-> Zig.
- Integration ZLib <-> Zig.
- Different options for API design (allocated vs. streaming via reader/writer).

## Features

- [x] Decrypting save files
- [x] Decompressing save files
- [ ] Deserializing YAML
- [ ] Serializing YAML
- [x] Loading base85 item serials
- [x] Saving base85 item serials
- [x] Compressing save files
- [x] Encrypting save files

## License

[MIT Open Source](./LICENSE)
