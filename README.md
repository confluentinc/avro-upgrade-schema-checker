# Avro Upgrade Schema Checker

A bash script that audits all Avro schemas in a Confluent Cloud Schema Registry
for compatibility with the stricter [Avro 1.12](https://avro.apache.org/docs/1.12.0/specification/)
validation being enabled in Confluent Cloud Schema Registry.

Avro 1.12 introduces enforcement of:

- **Valid namespaces** — names must start with `[A-Za-z_]`, contain only
  `[A-Za-z0-9_]`, and namespaces must be dot-separated sequences of such names.
  Reserved type names (`null`, `boolean`, `int`, `long`, `float`, `double`,
  `bytes`, `string`) are also not allowed as namespace components.
- **Correct field default values** — the JSON type of each default must match
  the field's Avro type. For unions, the default must be valid for at least one
  branch per the Avro 1.12 spec.

Use this tool to proactively identify and remediate problematic schemas before
Avro 1.12 validation is turned on, so that future schema registrations and
evolutions do not start failing unexpectedly.

## Prerequisites

- **bash** (4.x or later)
- **curl**
- **[jq](https://jqlang.github.io/jq/)** (1.6 or later)
- A Confluent Cloud Schema Registry endpoint with an API key and secret

## Usage

```bash
SR_URL=<your-schema-registry-url> \
SR_API_KEY=<your-api-key> \
SR_API_SECRET=<your-api-secret> \
  ./avro-namespace-default-field-check.sh
```

### Verbose mode

Add `-v` or `--verbose` to see detailed debug output including the specific
namespace values and field names that are invalid:

```bash
SR_URL=https://psrc-xxxxx.us-east-2.aws.confluent.cloud \
SR_API_KEY=ABCDEFGHIJK \
SR_API_SECRET=xyzSecretHere \
  ./avro-namespace-default-field-check.sh -v
```

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `SR_URL` | Yes | Schema Registry endpoint URL (e.g., `https://psrc-xxxxx.us-east-2.aws.confluent.cloud`) |
| `SR_API_KEY` | Yes | Schema Registry API key |
| `SR_API_SECRET` | Yes | Schema Registry API secret |

## Reading the results

The script outputs one line per violating schema version to **stdout**. Progress
and summary information is printed to **stderr**.

### Output format

Each violation line follows this format:

```
subject=<subject-name> | version=<version-number> | reason=<reason> [| bad_default_fields=<field1,field2>]
```

### Reason codes

| Reason | Description |
|---|---|
| `bad_namespace` | The schema contains a namespace that violates Avro 1.12 naming rules (e.g., starts with a digit, contains invalid characters, or uses a reserved type name). |
| `bad_default` | One or more fields have a default value whose JSON type is incompatible with the field's declared Avro type. The offending field names are listed in `bad_default_fields`. |
| `bad_namespace,bad_default` | Both issues were found in the same schema version. |
| `schema_parse_error` | The schema payload could not be parsed as valid JSON. This requires manual review. |

### Example output

```
subject=com.example.User-value | version=1 | reason=bad_namespace
subject=orders-value | version=3 | reason=bad_default | bad_default_fields=status,metadata
subject=events-value | version=2 | reason=bad_namespace,bad_default | bad_default_fields=payload
subject=broken-schema-value | version=1 | reason=schema_parse_error
```

### Summary

At the end of the run, the script prints a summary to **stderr**:

```
INFO: Checked 1234 Avro schema versions
INFO: 5 schema versions have potential namespace/default issues
```

If violations were found, the full list is reprinted to **stderr** for convenience.

### Saving results to a file

To capture only the violations to a file while still seeing progress on screen:

```bash
SR_URL=... SR_API_KEY=... SR_API_SECRET=... \
  ./avro-namespace-default-field-check.sh > violations.txt
```

To capture everything (violations + progress):

```bash
SR_URL=... SR_API_KEY=... SR_API_SECRET=... \
  ./avro-namespace-default-field-check.sh > violations.txt 2>&1
```

## Remediation

For each violation found:

1. **`bad_namespace`** — Update the schema's `namespace` field to comply with
   Avro naming rules. Ensure each dot-separated component starts with a letter
   or underscore and contains only alphanumeric characters and underscores.
2. **`bad_default`** — Update the field's `default` value to match its declared
   type. For example, a field of type `"int"` must have a numeric default (not a
   string), and a union field's default must be valid for at least one branch of
   the union.
3. **`schema_parse_error`** — Manually inspect the schema JSON in Schema
   Registry. The payload may be malformed or contain syntax errors.

## License

See [LICENSE](LICENSE) for details.
