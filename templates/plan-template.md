# [Feature Name] — Loop Plan

> **Execution:** Use `/loopbuild` to execute this plan.

**Goal:** [One-sentence description of what this feature achieves]
**Architecture:** [2-3 sentences describing the high-level approach, key components, and how they connect]
**Tech Stack:** [Key technologies, frameworks, and libraries involved]
**Has UI:** true/false

---

## Shared Interfaces

Contracts between work units. Each unit MUST respect these exactly.

### API Contract: [Name]

- Endpoint: `POST /api/things`
- Request: `{ name: string, type: "a" | "b" }`
- Response: `{ id: string, created_at: string }`
- Errors: `{ error: string, code: number }`

### Data Schema: [Name]

```typescript
interface Thing {
  id: string;
  name: string;
  type: "a" | "b";
  created_at: string;
  updated_at: string;
}
```

### Component Props: [Name]

```typescript
interface ThingCardProps {
  thing: Thing;
  onEdit: (id: string) => void;
  onDelete: (id: string) => void;
}
```

### Shared Types: [Name]

```typescript
type ThingType = "a" | "b";

enum ThingStatus {
  Active = "active",
  Archived = "archived",
}
```

---

## Architectural Decisions

Decisions all units must follow.

- [Decision 1: e.g., "Use server actions for mutations, not API routes"]
- [Decision 2: e.g., "All database access goes through the repository pattern in src/lib/db/"]
- [Decision 3: e.g., "Error responses follow { error: string, code: number } shape"]

---

## Work Units

### Unit 1: [Name] (estimated: N tasks)

**Scope:** [What this unit owns — e.g., "API layer for thing CRUD operations"]
**Depends on interfaces:** [Which shared interfaces this unit implements or consumes]
**Files:**
- Create: `src/api/things.ts`
- Create: `src/api/things.test.ts`
- Modify: `src/api/index.ts` (add route registration only)

**Tasks:**

- [ ] Step 1: Create the Thing API handler

```typescript
// src/api/things.ts
import { Thing } from "@/types";

export async function createThing(req: Request): Promise<Response> {
  const { name, type } = await req.json();
  // Full implementation here — no placeholders
  const thing: Thing = {
    id: crypto.randomUUID(),
    name,
    type,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  return Response.json(thing, { status: 201 });
}
```

- [ ] Step 2: Write tests for Thing API

```typescript
// src/api/things.test.ts
import { describe, it, expect } from "vitest";
import { createThing } from "./things";

describe("createThing", () => {
  it("creates a thing with valid input", async () => {
    // Full test implementation
  });
});
```

- [ ] Step 3: Register route in API index

```typescript
// src/api/index.ts — append to existing routes
import { createThing } from "./things";

router.post("/api/things", createThing);
```

---

### Unit 2: [Name] (estimated: N tasks)

**Scope:** [What this unit owns — e.g., "UI components for thing management"]
**Depends on interfaces:** [Which shared interfaces this unit implements or consumes]
**Files:**
- Create: `src/components/ThingCard.tsx`
- Create: `src/components/ThingList.tsx`
- Create: `src/pages/things.tsx`

**Tasks:**

- [ ] Step 1: Create ThingCard component

```tsx
// src/components/ThingCard.tsx
import { ThingCardProps } from "@/types";

export function ThingCard({ thing, onEdit, onDelete }: ThingCardProps) {
  return (
    <div>
      <h3>{thing.name}</h3>
      <span>{thing.type}</span>
      <button onClick={() => onEdit(thing.id)}>Edit</button>
      <button onClick={() => onDelete(thing.id)}>Delete</button>
    </div>
  );
}
```

- [ ] Step 2: Create ThingList component

```tsx
// src/components/ThingList.tsx
// Full implementation...
```

- [ ] Step 3: Create Things page

```tsx
// src/pages/things.tsx
// Full implementation...
```

---

## Acceptance Tests (Playwright)

### Scenario 1: User creates a new thing

1. Navigate to /things
2. Click "Create New"
3. Fill in name: "Test Thing"
4. Select type: "a"
5. Click Submit
6. Verify: redirected to /things/[id]
7. Verify: page heading contains "Test Thing"
8. Verify: type displays as "a"

### Scenario 2: User views thing list

1. Navigate to /things
2. Verify: page loads without errors
3. Verify: at least one ThingCard is visible
4. Verify: each card shows name and type

### Scenario 3: User deletes a thing

1. Navigate to /things
2. Click "Delete" on the first thing
3. Verify: confirmation dialog appears
4. Click "Confirm"
5. Verify: thing is removed from the list

---

## Smoke Test Coverage

Pages and routes that should load without errors:

- `GET /` → 200, no console errors
- `GET /things` → 200, no console errors
- `GET /api/health` → 200
- `GET /api/things` → 200, returns JSON array
- `POST /api/things` with valid body → 201, returns JSON object
