# PL/SQL Style Guide

Use this guide for Oracle SQL and PL/SQL packages in Core and applications built
on Core.

## General principles

- Optimize for scanability and consistency, not minimum line count.
- Preserve behavior during formatting-only changes.
- Use uppercase SQL and PL/SQL keywords and built-in function names.
- Use lowercase parameter and local-variable names. Prefix input parameters
  with `ip_`, output parameters with `op_`, input/output parameters with `iop_`,
  local variables with `l_`, and constants with `c_`.
- Anchor parameters and variables to owning columns with `%TYPE` whenever a
  table column defines the contract.
- Prefer Core facilities, such as `ASSERT`, over package-local duplicates after
  Core is installed. Core's initial bootstrap is an exception.
- Use named notation for calls with three or more arguments, optional
  arguments, or multiple arguments of the same type.
- End procedures and functions with their names.
- Apply these rules to new and materially changed code. Do not rename public
  parameters or reformat entire packages incidentally; parameter names are part
  of the API for callers that use named notation.

## Package structure

Start package files with a short identifying banner:

```sql
--
-- PKG_EXAMPLE (Package)
--
CREATE OR REPLACE PACKAGE PKG_EXAMPLE
AS
```

Organize package bodies with explicit sections:

```sql
  -- =========================================================================
  -- Private Procedures and Functions
  -- =========================================================================

  -- =========================================================================
  -- Public Procedures
  -- =========================================================================
```

Document public routines in the specification. Include a description and
document parameters whose purpose is not self-evident.

```sql
/**
 * @description Submit one immutable work request.
 * @param ip_client_name Registered client name.
 * @param op_request_id Identifier of the resulting request.
 */
```

## Procedure and function declarations

For multiline declarations, align the opening and closing parentheses and use
leading commas. Align parameter modes and types where practical.

```sql
  PROCEDURE SUBMIT_REQUEST
  (
      ip_client_name  IN  APP_CLIENT.CLIENT_NAME%TYPE
    , ip_external_key IN  APP_REQUEST.EXTERNAL_KEY%TYPE
    , ip_autocommit   IN  BOOLEAN DEFAULT TRUE
    , op_request_id   OUT APP_REQUEST.REQUEST_ID%TYPE
  );
```

Use an explicit name at the end:

```sql
  END SUBMIT_REQUEST;
```

## Assertions and exception handling

Use Core `ASSERT` for validation, invariant enforcement, and deliberate
translation to the standard `ORA-20000` assertion contract.

Keep short assertions on one line:

```sql
assert(l_count = 1, 'Expected exactly one row');
```

For multiline assertions, the opening parenthesis may remain with `assert`.
Put the argument-separating comma at the beginning of the message line.

```sql
assert(
    ip_status IN ('PENDING', 'READY')
    OR (ip_status = 'CLAIMED' AND ip_lease_expires_at < SYSTIMESTAMP)
  , 'Work item is not claimable'
);
```

Use `assert(FALSE, <message>)` when translating an expected exception. Roll
back only work owned by the routine; use a savepoint when the caller owns the
surrounding transaction:

```sql
SAVEPOINT submit_request_start;

BEGIN
    -- Perform the routine's work.
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        ROLLBACK TO submit_request_start;
        assert(FALSE, 'Owned work item was not found');
    WHEN OTHERS THEN
        ROLLBACK TO submit_request_start;
        RAISE;
END;
```

Retain plain `RAISE;` when the original exception must be preserved.

## SQL clause alignment

Right-align the ends of the principal SQL clause keywords:

```sql
SELECT r.request_id
     , r.request_status
  INTO l_request_id
     , l_request_status
  FROM app_request r
  JOIN app_client c
    ON c.client_id = r.client_id
 WHERE r.external_key = ip_external_key
   AND c.enabled = 'Y';
```

Rules:

- Put the first table on the same line as `FROM`.
- Put each `JOIN` on its own line.
- Put each `ON` clause on a separate line beneath its `JOIN`.
- Right-align `AND` with `WHERE`.
- In multiline `INTO` lists, right-align the leading comma with `INTO`.
- Use leading commas in `SELECT`, `INTO`, `SET`, column, and value lists.

For a left outer join, put `LEFT` on the line immediately before `JOIN` and
right-align both keywords with `FROM`:

```sql
  FROM app_request r
  LEFT
  JOIN app_result x
    ON x.request_id = r.request_id
```

## Inserts and updates

Use vertically paired column and value lists with aligned parentheses and
leading commas:

```sql
INSERT INTO app_request
(
    client_id
  , external_key
  , request_status
)
VALUES
(
    l_client_id
  , ip_external_key
  , 'PENDING'
);
```

Right-align `SET` with `UPDATE`. For multiline `SET` lists, right-align each
leading comma with `SET`, and align predicate continuations:

```sql
UPDATE app_request
   SET request_status = ip_request_status
     , updated_at = SYSTIMESTAMP
 WHERE request_id = ip_request_id
   AND request_status = 'PENDING';
```

## Calls and multiline function arguments

Use named notation for nontrivial package calls:

```sql
PKG_JOB_CONTROL.SUBMIT
(
    ip_task_name  => 'PROCESS_REQUEST'
  , ip_params     => TO_CHAR(ip_request_id)
  , ip_autocommit => FALSE
  , op_run_id     => l_run_id
);
```

For multiline function calls:

- indent arguments beneath the function call;
- use leading argument-separating commas;
- align opening and closing parentheses when practical;
- keep compact calls on one line when they remain easy to read.

```sql
l_key := COALESCE
(
    TRIM(ip_logical_key)
  , TRIM(ip_source_locator)
);

l_matches := INSTR(
    LOWER(ip_source_locator)
  , '%2e'
);
```

Use leading commas, not trailing commas, in multiline calls:

```sql
-- Avoid
l_value := SOME_FUNCTION(
    ip_first,
    ip_second
);
```

## Transactions

- Make transaction ownership explicit in public API documentation.
- Use savepoints when the caller owns the transaction or a procedure supports
  optional caller-controlled commit. Roll back to the routine's savepoint
  before translating an exception.
- Use a full `ROLLBACK` only when the routine explicitly owns the whole
  transaction, such as an autonomous transaction, and document that ownership.
- Never hide an unexpected exception; roll back as required and use `RAISE;`.

## Verification after style changes

Formatting must not alter behavior. At minimum:

1. Compile the package specification and body.
2. Check for invalid objects or compiler errors.
3. Run relevant database integration tests.
4. Run application/runtime tests.
5. Run `git diff --check`.
