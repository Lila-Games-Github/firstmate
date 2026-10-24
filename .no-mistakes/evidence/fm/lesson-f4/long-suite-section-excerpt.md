# Long-suite and evidence snapshot contract
When the definition of done requires a long-running suite, run it as a durable job that outlives one execution session: keep its progress and its identifier outside the process that started it (a log path plus a recorded job or session identifier), and reattach through that identifier instead of re-running the suite.
A required suite that is still running, or queued behind a shared suite lock, is work under way rather than a stalled task: report it as the declared external wait rule 4 defines, naming its identifier and what it is waiting on, and never abandon, duplicate, or restart it because one command call was killed, timed out, or hit an execution-session limit.
Evidence must describe one snapshot: every capture and artifact you cite and the final suite receipt must all name the same commit.
Either the landing tip is held still from the first capture through the final suite, or a tip that moved invalidates that evidence, and the re-capture budget is one re-capture and re-run - a second move is the same obstacle twice, so report it as a blocker rather than repeating.

