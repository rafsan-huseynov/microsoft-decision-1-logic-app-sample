# Production notes

This repo is a sample. Read this before you use the pattern with real messages.

## Run history stores messages

A stateful workflow keeps each run's inputs and outputs. That includes sender emails and message text.

In production, turn on secure inputs and outputs for the `manual` trigger and the `Classify_with_Decision1` action. Add this to each one in `workflow.json`:

```json
"runtimeConfiguration": {
  "secureData": { "properties": ["inputs", "outputs"] }
}
```

Secured values stay hidden in later actions that use them, such as `Decision_Summary`. Also set run history retention to match your privacy policy.

## The trigger URL is a secret

The trigger URL contains a SAS signature (`sig=`). Anyone with the URL can call the workflow.

- `test.sh` keeps the URL in memory only. It passes it to curl through stdin. It never prints it, logs it, or writes it to disk.
- If the URL leaks, regenerate the access keys to rotate it.
- For production callers, consider putting API Management or Easy Auth in front of it.

## One secret lives in Azure

`az logicapp create` stores the storage account connection string in the `AzureWebJobsStorage` app setting. It stays in Azure, never in this repo. You can switch the runtime storage to managed identity.

## Inputs and failures

- The trigger uses `"operationOptions": "EnableSchemaValidation"`, and `message` has `minLength: 1`. An empty or missing message gets HTTP 400 before any run starts.
- If the model call fails or times out, `Response_On_Failure` returns HTTP 502 with the model's status code.

## Decisions need review

- `Route_to_Marketing` and `No_Testimonial` are placeholders. Replace them with real actions, such as a Teams post, an email, or a queue message.
- The thresholds are starting points. Test them on your own labeled messages before you automate anything.
- Follow the [Microsoft-Decision-1 best practices](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision#best-practices). Keep a person in the loop before you publish anyone's story.

## Before you publish a fork

Run both checks before every push:

```bash
./scan.sh                    # GUIDs, non-example.com emails, SAS URLs, keys, and every value in your .env
gitleaks dir . --redact -v   # general secret scan
```

`scan.sh` reads your real values from `.env` at run time. It reports matches by key name only, so the values are never printed. Add other identifiers, such as your name or other resource names, to `SCAN_EXTRA_PATTERNS` in `.env`.
