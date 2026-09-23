# workspace-retirements.jsonl audit digest

- undefined: discard=none landing=
- ws-retire-incomplete-success: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-retire-incomplete-success: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-retire-malformed-route: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-worker-alt: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-retire-cache: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-retire-ignored-discard: discard={"authorization":"discard ignored work","commits":[],"allow":["ignored-files"]} landing=remote
- ws-retire-discard: discard={"authorization":"whatever local changes are there, if it's not needed can be discarded","commits":["0c9f53c38ef3b310676fe923941408dd362d0fee"],"allow":["tracked-modifications","untracked-files","unlanded-commits"]} landing=remote
- ws-retire-missing: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-retire-orphan-cache: discard={"authorization":null,"commits":[],"allow":[]} landing=
- ws-retire-orphan-files: discard={"authorization":"discard it","commits":[],"allow":["orphaned-files"]} landing=
- ws-retire-missing-detached: discard={"authorization":"discard it","commits":["c9093d00913ab4ee2b1d4bda75090ac5c4fddc13"],"allow":["unlanded-commits"]} landing=remote
- ws-retire-missing-bystander: discard={"authorization":null,"commits":[],"allow":[]} landing=remote
- ws-retire-pair-a: discard={"authorization":"discard both","commits":["e6f809255a9d4913fb2a00be6f89740546e0cc15","aad0908203965ba8f57a74d70813eaa0f1b1fe7c"],"allow":["unlanded-commits","prune-would-drop-unlanded-head"]} landing=remote
- ws-retire-pair-b: discard={"authorization":"discard both","commits":["aad0908203965ba8f57a74d70813eaa0f1b1fe7c"],"allow":["unlanded-commits"]} landing=remote
- ws-retire-local-landed: discard={"authorization":null,"commits":[],"allow":[]} landing=local-branch