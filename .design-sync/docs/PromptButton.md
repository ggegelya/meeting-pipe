---
category: Controls
---
The compact 26px-high action button used in the meeting prompt's cluster: default (raised, bordered), `primary` (signal-600 fill), or `chevron` (narrow, for the overflow menu trigger).
Realistic labels are short verbs: "Record", "Record (BYO)", "Skip". Pass an `<Icon name="chevron-down" size={12} />` child with `chevron` for the menu variant.

```jsx
<PromptButton primary>Record</PromptButton>
<PromptButton>Record (BYO)</PromptButton>
<PromptButton chevron><Icon name="chevron-down" size={12} /></PromptButton>
```
