## Writing style: 80% ASD-STE100

Write about 80% of the way to ASD-STE100 Simplified Technical English (STE). Follow the STE writing rules below. Use the plainest common word, but do not limit your words to the STE dictionary.

Use this style for everything you write to me: answers, explanations, summaries, plans, reviews, and PR descriptions. Do not use it for code, code comments, commit messages, quoted text, or user-facing copy such as menu items, Settings labels, overlay status messages, alerts, and permission prompts. User-facing copy keeps its own voice.

Apply these rules to every message to me. This includes short replies and status updates.

### Words

- Use the plainest common word. Write "use", not "utilize" or "leverage". Write "start", not "initiate".
- Use one word for one thing. After you name a thing, use the same name every time. For example, do not use "draft transcript", "raw text", and "first pass" for the same text.
- Use a verb for an action, not a noun. Write "test the build", not "do a test of the build". Write "decide", not "make a decision".
- Use a one-word verb when you can. Write "find", not "figure out". Write "check", not "look into". Write "remove", not "get rid of".
- Do not use idioms, slang, or metaphors, such as "out of the box", "under the hood", "low-hanging fruit", or "moving forward".
- Do not use filler words, such as "just", "simply", "basically", "actually", "really", "quite", or "a bit".
- Do not use contractions. Write "do not", "it is", and "cannot".
- Use "must" for a requirement, "can" for a possibility, and "I recommend" for advice. Do not use "should" or "may", because they have more than one meaning.

### Verbs

- Use only these verb forms: the infinitive, the imperative, the simple present, the simple past, and the future with "will". You can also use a past participle as an adjective, as in "the saved recording".
- Do not use perfect tenses. Write "I changed the test", not "I have changed the test".
- Do not use continuous tenses. Write "the build fails", not "the build is failing".
- Do not use -ing words as verbs or nouns. Write "before you run the tests", not "before running the tests". You can use technical names such as "recording" and "streaming".
- Use the active voice. Write "the app keeps the draft", not "the draft is kept".
- Say who does each action. Write "I" for what you did and "you" for what I must do: "I changed the test. You must restart the app."

### Sentences

- Write short sentences. Use a maximum of 20 words in an instruction and 25 words in a description. Count an identifier, a file path, a command, or a number as one word.
- Write only one instruction or one topic in each sentence.
- Put a condition before the instruction, and put a comma after the condition: "If the build fails, send me the full error."
- Do not remove words to make text shorter. Keep "the", "a", "an", and "that". Write "I fixed the parser. The tests pass." Do not write "Fixed parser, tests pass."
- Do not join two sentences with a semicolon or a dash. Write two sentences.
- Use "this", "that", "these", and "those" before a noun. Write "this change fixes the crash", not "this fixes it".
- Do not make noun clusters of more than three nouns. Write "the timeout of the cleanup request", not "the transcript cleanup request timeout".

### Paragraphs and lists

- Start with the most important information: the result, the answer, or the decision.
- Write about only one topic in each paragraph. Use a maximum of six sentences in a paragraph.
- Use a numbered list for steps in a sequence. Use bullets for items that have no sequence.
- Use connecting words to show the logic: "because", "but", "then", "if", "when", "after", and "before".
- To warn me about a risk, start with the command. Then give the risk in one short sentence: "Do not use Clear Transcript History to test this change. It permanently deletes all archived recordings and transcripts."
- If you are not sure about a fact, say so one time and give the reason: "I did not test this on macOS 13." Do not add "might" or "probably" to other sentences.

### Before you send

Read your message again. Correct these problems before you send it:

- a sentence with more than 25 words
- "has", "have", or "had" before a past participle
- an -ing verb, a continuous tense, or the passive voice
- a filler word, an idiom, a phrasal verb, or a contraction
- a noun cluster of more than three nouns

### Examples

Not STE:

> I've gone ahead and refactored the cleanup flow so that it's now falling back to the draft transcript whenever the OpenRouter request ends up failing, which should hopefully make things a bit more robust going forward.

80% STE:

> I changed the cleanup step. If the OpenRouter request fails, the app keeps the draft transcript. You can then retry the cleanup.

Not STE:

> To try it out, you'll want to rebuild the app and then go ahead and do a quick test dictation to make sure everything's working.

80% STE:

> 1. Run `./rebuild-app.sh`.
> 2. Press Option+Space to start a recording.
> 3. Say one sentence.
> 4. Press Option+Space to stop the recording.
> 5. Make sure that the transcript appears in the active app.

## Install after each change

Marc tests the installed app, so a code change is done only when that app runs it. After the build and tests pass, run `./rebuild-app.sh`. It builds, signs, installs, and relaunches `~/Applications/SuperSamuel.app`, and macOS keeps its permissions.

The relaunch quits the running app and cuts any recording in progress. Run it only when SuperSamuel is idle: no manifest in `~/Library/Application Support/SuperSamuel/Recordings/*/manifest.json` has the status `recording` or `processing` with a file written in the last 20 seconds. If SuperSamuel is busy, wait in a background job, then install.
