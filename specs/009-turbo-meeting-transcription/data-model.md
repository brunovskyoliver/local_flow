# Data model

No database migration. Existing transcript-pass model ID, revision, manifest hash, engine and planner fields identify final Turbo output. New geometry is distinct from the fixed Parakeet geometry. ModelWorkload adds meetingTranscription; default remains speechRecognition. ModelDescriptor.File may carry an optional immutable sourceURL; its size and SHA-256 remain mandatory. Settings tracks Turbo installation separately from Parakeet and speaker assets.
