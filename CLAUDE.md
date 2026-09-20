# River Diary agent routing

When a user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

## Skill routing

- Product ideas and brainstorming → `/office-hours`
- Strategy and scope → `/plan-ceo-review`
- Architecture and engineering review → `/plan-eng-review`
- Design system and visual identity → `/design-consultation`
- Design plan review → `/plan-design-review`
- Full review pipeline → `/autoplan`
- Bugs and errors → `/investigate`
- QA and site behavior → `/qa` or `/qa-only`
- Code review and diff checks → `/review`
- Visual polish → `/design-review`
- Ship, deploy, or PR → `/ship` or `/land-and-deploy`
- Save progress → `/context-save`
- Resume context → `/context-restore`
- Backlog-ready spec or issue → `/spec`
