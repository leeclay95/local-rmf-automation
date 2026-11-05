---
name: stig-answerfile-validation
description: Write or review PowerShell <ValidationCode> for Evaluate-STIG answer files (Template_AnswerFile.xml). Use when authoring an answer file, a <Vuln>/<AnswerKey>/<Answer> block, or validation code that sets a STIG check to NotAFinding / Open / Not_Applicable, or when an answer file silently fails to apply.
---

# Evaluate-STIG answer file validation code

`<ValidationCode>` is PowerShell that Evaluate-STIG runs to decide whether a
documented answer applies to the host it is scanning right now. It is the only
executable part of an answer file, and it fails **silently** when written wrong —
the scan completes, the check keeps the wrong status, and the only trace is one
line in the scan log. Write it defensively.

## The contract

Return exactly one of:

- `[bool]` — `$true` or `$false`.
- `[hashtable]` with **both** keys: `Valid` (`[bool]`) and `Results` (`[string]`).
  `Results` is written into the check's Comments field.

Nothing else is accepted. `$Validated` is then compared with `-eq $true`, and
Evaluate-STIG applies `<ValidTrueStatus>`/`<ValidTrueComment>` or
`<ValidFalseStatus>`/`<ValidFalseComment>` accordingly. A blank status element
means "leave the status unchanged".

**Prefer the hashtable.** The boolean form gives a reviewer nothing to audit; the
hashtable puts the evidence in the CKL, which is the whole point of an answer
file. Use a bare boolean only for a one-line test whose meaning is obvious from
`<ValidTrueComment>`.

## How it actually runs — the five failure modes

Verified in `Modules/Master_Functions/Master_Functions.psm1`, `Get-CorporateComment`
(~L6019-6270). Your code is **string-concatenated** into a wrapper and compiled
with `[scriptblock]::Create()`, then invoked with `&` in-process (default) or in a
child `pwsh`/`powershell` process when the caller passes `-UseSubProc`.

The wrapper is, in effect:

```powershell
Try {
    $ErrorActionPreference = "Stop"
    Set-Variable ExpectedStatus -Value "<status>"
    Import-Module <ESPath>/Modules/Master_Functions
    # ---- your ValidationCode is spliced in here ----
}
Catch {
    $ValidationResults = @{ Valid = $False; Results = "ERROR: $($_.Exception.Message)" }
    Return $ValidationResults
}
```

That design produces five distinct ways to fail, and four of them are quiet:

1. **Stray output poisons the return value.** `& $PSScriptBlock` collects the
   whole output stream. Any uncaptured pipeline output — `Get-Item ...` on its own
   line, an assignment-free function call, `Write-Output` — makes
   `$ValidationResult` an `Object[]`. The type switch has no case for that, logs
   `Invalid ValidationCode object returned`, and leaves `$Validated` unset, so the
   **ValidFalse** branch applies. Suppress every non-return statement:
   `$null = ...`, `| Out-Null`, or assign it.
2. **Returning nothing discards the whole answer.** The code calls
   `$ValidationResult.GetType().Name` unguarded. On `$null` that throws, the
   function's outer `Catch` sets `$AnswerResults = $null`, and the answer file is
   not applied *at all* — not even the false branch. Every path must `return`.
3. **`$ErrorActionPreference = "Stop"` is forced.** A cmdlet error that you would
   normally shrug off becomes terminating and is converted to
   `@{Valid=$false; Results="ERROR: ..."}`. That is a safe landing, but it is
   indistinguishable from a legitimate `$false` unless you handle it yourself.
   Wrap anything that touches the registry, the filesystem, WMI/CIM or a network
   path in your own `try/catch` and write a specific `Results` string.
4. **Truthy is not boolean.** `return "true"`, `return 1`, `return @($true)` all
   land in the type switch's default case → treated as not-valid. Cast
   explicitly: `return [bool]$Result`.
5. **A hashtable missing a key is rejected.** The switch requires `Valid` *and*
   `Results` to be present. Initialize both up front.

## Variables available

`$ExpectedStatus` is always set by the wrapper. The rest come from Evaluate-STIG:

| Variable | Type | Notes |
|---|---|---|
| `$ESPath` | String | Path Evaluate-STIG.ps1 ran from |
| `$ExpectedStatus` | String | CKL-format status Evaluate-STIG determined |
| `$ResultHash` | String | SHA1 of `$ResultData` |
| `$ResultData` | Array | FindingDetails content after the `~~~~~` bar |
| `$Hostname` | String | |
| `$Username`, `$UserSID` | String | HKCU checks |
| `$Instance`, `$Database` | String | SQL checks |
| `$Site` | String | IIS checks |
| `$ShowRun` | Array | `Show-RunningConfig` section, Cisco |

Two caveats that are not in the template's documentation:

- **In the default in-process path, only `$ExpectedStatus` is injected.** The
  others are visible solely because PowerShell child scopes can read the caller's
  variables. Treat them as read-only and never assume one is populated — guard
  with `if ($Instance)` rather than indexing straight into it.
- **In `-UseSubProc` mode the array variables arrive as a single string.**
  `$ResultData` and `$ShowRun` are interpolated into a double-quoted string, so
  the array is space-joined, and `"` characters in the data are rewritten to `'`.
  Code that does `$ResultData[2]` or `$ResultData.Count` gives different answers
  in the two modes. Write against the text, not the indices:

```powershell
$Text = ($ResultData -join "`n")
if ($Text -match 'MinimumPasswordAge\s*:\s*(\d+)') { ... }
```

`Master_Functions` is imported before your code, so its exported helpers are
callable. Prefer them over re-implementing platform probing, but check that the
function you want is actually exported (`Get-Command -Module Master_Functions`)
before relying on it.

## XML, not a .ps1 file

`<ValidationCode>` is element text (`xs:string` in the GUI's schema), so XML rules
win over PowerShell's:

- `&` must be `&amp;`, `<` must be `&lt;`, `>` should be `&gt;`.
- **Never use `<`, `>` or `&` as operators or redirection.** Write `-lt`, `-gt`,
  `-le`, `-ge`, `-and`, `-band`; use `2>$null`'s replacement
  `-ErrorAction SilentlyContinue`; use `-join`/`Set-Content` instead of `>`.
- Do not use `--%`, and do not put `-->` inside a comment.
- **Avoid CDATA.** The shipped template does not use it and the GUI answer-file
  editor never writes it, so a CDATA block may not survive a GUI round-trip.
  Escaped text is the supported form.
- Keep lines short and indented inside the element. The GUI stores
  `.ValidationCode.Trim()`, so leading/trailing whitespace is not preserved —
  don't rely on it.

A practical consequence: write comparisons and string tests with PowerShell's
word operators everywhere, even when a `<` would read better. If a check genuinely
needs `-lt` against a parsed number, parse first and compare on a typed variable.

## Canonical shape

Start from this and delete what you do not need. It satisfies every rule above:

```xml
<Answer Index="1" ExpectedStatus="O" Hostname="" Instance="" Database="" Site="" ResultHash="">
  <ValidationCode>
    $ValidationObject = @{
        Valid   = $false
        Results = "Validation did not run."
    }

    try {
        $Key  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        $Name = "EnableSmartScreen"

        $Item = Get-ItemProperty -Path $Key -Name $Name -ErrorAction Stop
        if ([int]$Item.$Name -ge 1) {
            $ValidationObject.Valid   = $true
            $ValidationObject.Results = "$Name is $($Item.$Name) (compliant, -ge 1)."
        }
        else {
            $ValidationObject.Valid   = $false
            $ValidationObject.Results = "$Name is $($Item.$Name); expected -ge 1."
        }
    }
    catch {
        $ValidationObject.Valid   = $false
        $ValidationObject.Results = "ERROR reading ${Key}\${Name}: $($_.Exception.Message)"
    }

    return $ValidationObject
  </ValidationCode>
  <ValidTrueStatus>NF</ValidTrueStatus>
  <ValidTrueComment>Mitigated by GPO; verified by validation code at scan time.</ValidTrueComment>
  <ValidFalseStatus></ValidFalseStatus>
  <ValidFalseComment>Expected mitigation not present at scan time; finding stands.</ValidFalseComment>
</Answer>
```

Points to copy, not just the shape:

- `Results` is initialized to a *sentence that is wrong on purpose*. If the
  validation never reaches a decision, the CKL says so instead of lying.
- `ValidFalseStatus` is **blank** — the finding keeps the status Evaluate-STIG
  determined. Only set it when you intend to *downgrade or escalate* on failure.
- Both comments state what was proven, not what was assumed. These end up in front
  of an assessor.
- The error branch names the thing it could not read.

### Matching on scan output instead of the live system

When the evidence is already in FindingDetails, read `$ResultData` rather than
re-probing the host — it is faster and cannot disagree with the scan:

```powershell
$ValidationObject = @{ Valid = $false; Results = "No matching line in FindingDetails." }
$Text = ($ResultData -join "`n")

if ($Text -match '(?m)^\s*Status\s*:\s*Disabled\s*$') {
    $ValidationObject.Valid   = $true
    $ValidationObject.Results = "FindingDetails reports the service Disabled."
}
return $ValidationObject
```

If the answer should apply only to one exact observed output, set the `ResultHash`
attribute on `<Answer>` instead of hashing inside the code — Evaluate-STIG matches
it for you, and it is visible to a reviewer.

## The surrounding attributes decide whether your code runs at all

Validation code is reached only after an `<Answer>` is selected:

- **`ExpectedStatus` is a hard gate, weight 0.** If it does not equal the status
  Evaluate-STIG determined (compared in CKL form), the answer is ignored and the
  code never executes. Writing validation code that "fixes" a check whose
  `ExpectedStatus` is wrong is the most common wasted effort here.
- **Specificity wins by weight**, summed over populated, *applicable* attributes:
  `<AnswerKey Name>` 16, `Hostname` 5, `Instance` 4, `Database` 3, `Site` 2,
  `ResultHash` 1. An attribute that does not apply to the STIG contributes 0.
  A key named `DEFAULT` adds no weight, so a named key always beats it.
- `Name` on `<STIGComments>` must match the STIG ShortName from
  `-ListSupportedProducts`, or the file is never loaded for that STIG.
- `<Vuln ID>` takes a VulnID (`V-223311`) or a RuleID
  (`SV-223311r960963_rule`) — **commit to one per file**; the lookup takes the
  first match only.
- Status values accept EvalSTIG shorthand (`NR`, `NF`, `O`, `NA`) or the long CKL
  forms; they are normalized with `Convert-Status`.

## Before you call it done

Two scripts ship beside this file. Use them — the failure modes above are quiet
enough that eyeballing the snippet does not catch them.

```bash
SK=.claude/skills/stig-answerfile-validation

# 1. Extract the snippet. This also proves the XML escaping survived: what comes
#    out is exactly what Evaluate-STIG splices into its wrapper.
python3 -I $SK/extract-validationcode.py answerfile.xml V-251550 1 > snippet.ps1

# 2. Parse-check it.
pwsh -NoProfile -Command '$t=$null;$e=$null;
  $null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./snippet.ps1),[ref]$t,[ref]$e);
  if ($e.Count) { $e | ForEach-Object { $_.Message } } else { "parse OK" }'

# 3. Run it the way Evaluate-STIG does, and check the return value is acceptable.
pwsh -NoProfile -Command "& $SK/test-validationcode.ps1 -CodeFile ./snippet.ps1"

# With real scan output, and then the way -UseSubProc would mangle it:
pwsh -NoProfile -Command "& $SK/test-validationcode.ps1 -CodeFile ./snippet.ps1 \
  -ResultData (Get-Content ./finding-details.txt)"
pwsh -NoProfile -Command "& $SK/test-validationcode.ps1 -CodeFile ./snippet.ps1 \
  -ResultData (Get-Content ./finding-details.txt) -SimulateSubProc"
```

`test-validationcode.ps1` exits non-zero and names the rule you broke. Run the
last two together: if `Valid` differs between them, the code depends on
`$ResultData` being a real array and will behave differently under `-UseSubProc`.

Note the array arguments go through `pwsh -Command`, not `-File`. A bash shell
will not pass `@(...)` or a comma-separated list through `-File` intact.

Checklist for review:

- Every exit path `return`s a bool or a `Valid`+`Results` hashtable — no path falls off the end.
- No bare pipeline output anywhere; non-return statements are `$null =`-assigned or `Out-Null`ed.
- No `<`, `>` or raw `&` outside XML entities.
- External access (registry, file, CIM, network) is inside a `try/catch` that writes a specific `Results`.
- `Results` says what was *observed*, and is wrong-by-default before the decision is made.
- `ValidTrueStatus`/`ValidFalseStatus` are blank unless a change of status is intended.
- `ExpectedStatus` matches the status Evaluate-STIG actually produces for this check on this host.
- Nothing in the code assumes `$ResultData` is a real array (subproc mode flattens it).

After a scan, confirm it ran: the log line is `Executing Answer File ValidationCode`,
followed by `ValidationResult: ...`. `Invalid ValidationCode object returned` means
rule 1 or 4; no line at all means the answer was never selected (`ExpectedStatus`
or an attribute mismatch), or the code returned `$null` and took the whole answer
down with it.

## Reference

- Template and attribute docs: `Src/Evaluate-STIG/AnswerFiles/Template_AnswerFile.xml`
- Execution, type switch, status/comment wiring: `Src/Evaluate-STIG/Modules/Master_Functions/Master_Functions.psm1`, `Get-CorporateComment`
- Answer selection and weighting: same file, `Get-ESBestAnswerKey`
- Schema and the GUI editor: `Src/Evaluate-STIG/Evaluate-STIG_GUI.ps1`
- Shipped beside this file: `test-validationcode.ps1` (runs a snippet the way
  Evaluate-STIG does and judges the return value), `extract-validationcode.py`
  (pulls `<ValidationCode>` out of an answer file)
