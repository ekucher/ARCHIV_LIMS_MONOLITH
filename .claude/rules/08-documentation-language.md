# Documentation Language Policy

All project documentation is written exclusively in Ukrainian.

Scope includes:

- README files;
- CHANGELOG entries;
- files under `docs/`;
- operator runbooks;
- architecture/design notes;
- documentation-purpose comments (not general inline code comments);
- PR/issue descriptions when they function as formal project documentation.

Only technical terms remain in English, in their original form, without
translation:

- command names, CLI flags, and parameters;
- code identifiers (function, variable, file, and path names);
- product, technology, and protocol names;
- configuration keys, exit-code names, and API/field names.

Do not translate proper names, configuration keys, exit codes, or API/parameter
names merely for consistency with the rest of the text.

This rule governs project documentation. It does not itself change existing
practice for in-code comments outside documentation-purpose files.

Maintain full Ukrainian orthographic correctness, including required
diacritical marks and accents — never substitute them with ASCII equivalents.
