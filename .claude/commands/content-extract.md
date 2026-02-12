Review this project's SCOPE.md, DECISIONS.md, README.md, and any architecture documentation. Identify the most interesting, novel, or hard-won technical insight from this work — something that other engineers building similar systems would find valuable.

## Rules
- **No customer names.** Ever. Anonymize to industry verticals ("a Fortune 5 financial institution", "a global hospitality company").
- **No proprietary Akamai information.** Focus on the architectural pattern and engineering decisions, not internal product details.
- **Practitioner voice.** Write like an engineer sharing what they learned, not a vendor pitching a product. First person. Specific. Opinionated where warranted.
- **Lead with the problem.** Every piece of content should start with a problem the reader recognizes, not with a solution they haven't asked for.

## Generate these three content pieces:

### 1. LinkedIn Post (600-1000 words)

Structure:
- **Hook** (1-2 sentences): A provocative or surprising observation from this work. Something that makes a scrolling engineer stop.
- **The Problem** (2-3 sentences): What real-world constraint or challenge drove this architecture?
- **The Insight** (main body): What did you learn that wasn't obvious? What did the docs not tell you? What broke first under load? What would you do differently?
- **The Pattern** (2-3 sentences): Abstract the insight into a reusable principle.
- **Call to engagement** (1 sentence): A question that invites practitioners to share their experience.

Tone: Confident but not arrogant. Specific numbers and concrete examples. No buzzword salad. No "In today's rapidly evolving landscape..." openers.

### 2. Conference Talk Abstract (200 words max)

Target venues: KubeCon, Kafka Summit, SCALE, Akamai Edge Live, local cloud meetups.

Structure:
- **Title**: Specific, slightly provocative. Not generic. Bad: "Scaling MQTT in the Cloud". Good: "What Happens After 500K MQTT Subscribers: Lessons from Edge-Native Messaging"
- **Abstract**: Problem → approach → specific results/learnings → what the audience will take away.
- **Suggested talk length**: 25 or 40 minutes.
- **Target audience**: [who specifically benefits from this talk]

### 3. Thread Outline (5-7 posts)

For LinkedIn or X/Twitter. Each post should be self-contained but build on the previous:
- Post 1: The hook / surprising finding
- Post 2: Context — what were we building and why
- Post 3-5: The meaty insights (one per post, with a data point or diagram reference each)
- Post 6: The generalizable takeaway
- Post 7: Question / invitation to discuss

Each post: 2-4 sentences max. Concrete, not abstract.

## Output

Save all three pieces to `docs/content-draft.md` with clear section headers.

Also output a brief assessment:

```
## Content Viability
- **Novelty**: [High/Medium/Low] — How unique is this insight?
- **Audience**: [Who specifically cares about this?]
- **Best channel**: [LinkedIn post / Conference talk / Blog post / All three]
- **Timeliness**: [Is there a current industry conversation this plugs into?]
- **Risk check**: [Any customer-identifiable details that slipped through?]
```

If the project doesn't have a genuinely interesting insight worth publishing, say so. Not every project produces content. Better to publish nothing than to publish filler.
