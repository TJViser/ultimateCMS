# Isolation des agents IA — Architecture et reflexions

> Date : 19 mars 2026
> Statut : reflexion / exploration — aucun code modifie

---

## Le probleme

Aujourd'hui, **une seule instance de l'agent IA (Claude)** traite les edits de tous les clients. Quand un contributeur soumet un changement :

1. L'agent recoit le contenu des fichiers du repo GitHub du client
2. Il analyse le code source, les templates, les fichiers de donnees
3. Il produit les edits et cree une PR

**Le risque** : le meme endpoint API Anthropic recoit les contenus de tous les repos de tous les clients. Meme si Claude ne "retient" pas les donnees entre les appels (pas de memoire persistante), il y a plusieurs vecteurs de risque :

- **Fuite par prompt injection** : un fichier malveillant dans un repo pourrait tenter d'extraire des infos sur les requetes precedentes ou modifier le comportement de l'agent
- **Confiance centralisee** : le client doit faire confiance a UltimateCMS ET a Anthropic pour la confidentialite de son code
- **Compliance** : certains clients (finance, sante, gouvernement) ne peuvent pas envoyer leur code source a un tiers
- **Single point of failure** : si la cle API Anthropic est compromise, tous les clients sont exposes

---

## La vision : isolation par containeurisation

L'idee : chaque client (ou chaque tier de pricing) a son **propre agent IA isole**, qui n'a acces qu'a ses repos.

### Architecture cible

```
                                  ┌──────────────────────────────────────┐
                                  │        UltimateCMS Platform          │
                                  │                                      │
                                  │  app.rb (API, auth, routing)         │
                                  │         │                            │
                                  │         ▼                            │
                                  │  Agent Router / Orchestrator         │
                                  │         │                            │
                                  └─────────┼────────────────────────────┘
                                            │
                    ┌───────────────────────┼───────────────────────┐
                    │                       │                       │
                    ▼                       ▼                       ▼
          ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
          │  Agent Pool     │    │  Agent Dedie     │    │  Agent Client   │
          │  (Free/Pro)     │    │  (Team)          │    │  (Enterprise)   │
          │                 │    │                  │    │                 │
          │  Cle API partagee│    │  Cle API dediee  │    │  Infra client   │
          │  Container isole │    │  Container isole │    │  (self-hosted)  │
          │  Rate-limited   │    │  Prioritaire     │    │  LLM au choix   │
          └─────────────────┘    └─────────────────┘    └─────────────────┘
```

---

## 3 niveaux d'isolation proposes

### Niveau 1 — Isolation logique (Free / Pro)

**Quoi** : un pool partage de containers, mais chaque requete est isolee par site_key.

**Comment** :
- Chaque appel a Claude est **stateless** (c'est deja le cas) — pas de conversation persistante, pas de memoire entre requetes
- Les fichiers d'un client A ne sont jamais envoyes dans le meme prompt qu'un client B (c'est deja le cas — chaque `POST /api/edit` ne traite qu'un seul site)
- On peut ajouter un **prefixe systeme** dans le prompt qui rappelle a l'agent de ne jamais reveler le contenu des fichiers dans sa reponse
- **Cle API Anthropic** : partagee, mais chaque appel est independant

**Securite** : isolation par conception. Le modele ne retient rien entre les appels. Le risque residuel est sur Anthropic (stockage des logs, etc.), mais c'est couvert par leur politique de confidentialite API.

**Effort** : quasi nul — c'est deja comme ca que ca fonctionne. Juste documenter et ajouter le prefixe systeme.

---

### Niveau 2 — Container dedie par client (Team / Premium)

**Quoi** : chaque client Team a son propre "agent" avec sa propre cle API et ses propres limites.

**Comment** :

```
┌─────────────────────────────────────────────────────┐
│  Agent Orchestrator                                  │
│                                                      │
│  POST /api/edit                                      │
│    │                                                 │
│    ├── site.tier == 'free'  → Pool partage           │
│    ├── site.tier == 'team'  → Container dedie        │
│    └── site.tier == 'enterprise' → Endpoint client   │
│                                                      │
│  Chaque container dedie :                            │
│    - Sa propre cle API Anthropic (ou celle du client)│
│    - Son propre rate limit                           │
│    - Ses propres logs (isoles)                       │
│    - Pas d'acces aux fichiers d'autres clients       │
└─────────────────────────────────────────────────────┘
```

**Options de containerisation** :
- **Docker containers** : un container par client Team, orchestre par Kubernetes ou ECS
- **Serverless functions** (AWS Lambda, Cloud Run) : un "worker" par requete, naturellement isole
- **Microservice dedie** : l'`EditAgent` devient un service HTTP independant, deploye N fois

**Modele de cle API** :
- Option A : UltimateCMS fournit des cles API Anthropic separees par client (on cree des sub-keys via l'API Anthropic)
- Option B : le client fournit sa propre cle API Anthropic → on l'utilise pour ses requetes
- Option C : mix — cle par defaut fournie par UltimateCMS, avec possibilite de BYOK (Bring Your Own Key)

**Avantages** :
- Isolation forte : meme si un container est compromis, il n'a acces qu'aux repos d'un seul client
- Metering naturel : on sait exactement combien chaque client consomme
- Le client peut voir ses propres logs sans voir ceux des autres

**Effort** : moyen. Il faut refactorer `EditAgent` en service HTTP, ajouter un orchestrateur, gerer le cycle de vie des containers.

---

### Niveau 3 — Infrastructure client / BYOAI (Enterprise)

**Quoi** : le client Enterprise deploie son propre agent IA sur sa propre infra. UltimateCMS ne voit jamais son code source.

**Comment** :

```
┌──────────────────────────────┐     ┌──────────────────────────────┐
│  UltimateCMS Platform        │     │  Infra Client Enterprise     │
│                              │     │                              │
│  editor.js (frontend)        │     │  Agent Worker (self-hosted)  │
│      │                       │     │    │                         │
│      ▼                       │     │    ├── Claude / GPT / Llama  │
│  POST /api/edit              │     │    ├── Acces direct au repo  │
│      │                       │     │    └── Retourne les edits    │
│      ▼                       │     │          │                   │
│  Proxy → appelle l'endpoint ─┼────►│          ▼                   │
│  du client                   │     │    { file, old, new }        │
│      ◄───────────────────────┼─────┤                              │
│      │                       │     │  Le code source ne quitte    │
│      ▼                       │     │  JAMAIS l'infra du client    │
│  Cree la PR via GitHub API   │     └──────────────────────────────┘
│  (avec le token contributor) │
└──────────────────────────────┘
```

**Interface entre UltimateCMS et l'agent client** :

On definirait un **protocole standard** (API contract) que l'agent du client doit implementer :

```
POST /agent/analyze

Request:
{
  "page": { "url": "...", "path": "...", "title": "..." },
  "changes": [
    { "old_text": "...", "new_text": "...", "context": { ... } }
  ],
  "files": {
    "src/index.html": { "content": "...", "sha": "..." },
    "data/content.json": { "content": "...", "sha": "..." }
  }
}

Response:
{
  "edits": [
    { "file": "src/index.html", "old": "exact old string", "new": "exact new string" }
  ]
}
```

**Variante encore plus securisee** : le client fournit un endpoint et ses propres credentials GitHub. UltimateCMS envoie uniquement les changements textuels (pas les fichiers) et l'agent du client fait lui-meme le `git search` + `git read` + analyse. Le code source ne transite jamais par nos serveurs.

**Ce que le client peut plugger** :
- Claude (Anthropic) avec sa propre cle
- GPT-4 (OpenAI) avec son propre deployment Azure OpenAI
- Un LLM open-source (Llama, Mistral) heberge on-premise
- Un modele fine-tune sur son propre codebase (encore plus precis)
- N'importe quel service qui respecte le contrat API

**Avantages** :
- Zero trust : le code source ne quitte jamais l'infra du client
- Compliance : compatible avec les exigences les plus strictes
- Flexibilite : le client choisit son modele, sa config, ses guardrails
- Performance : le client peut pre-indexer son repo pour des recherches plus rapides

**Effort** : eleve. Il faut definir et documenter le protocole, fournir un SDK/template d'agent, gerer l'authentification entre UltimateCMS et l'endpoint client, supporter les erreurs de communication.

---

## Impact sur le pricing

La vraie frontiere entre Free et Pro n'est pas l'isolation (les deux utilisent le pool partage) — c'est le **nombre de sites**. Un freelance ou un dev perso n'a besoin que d'un seul repo. Des qu'on parle d'une agence ou d'une equipe qui gere plusieurs sites clients, c'est du Pro.

| Tier | Sites | Edits/mois | Contributors | Isolation | Cle API | Prix indicatif |
|------|-------|------------|--------------|-----------|---------|----------------|
| **Free** | **1 site** | 10 | 1 | Pool partage | UltimateCMS | $0/mois |
| **Pro** | **10 sites** | Illimite | 10 par site | Pool partage | UltimateCMS | $19/mois |
| **Team** | **Illimite** | Illimite | Illimite | Container dedie | Dediee ou BYOK | $49/mois |
| **Enterprise** | Illimite | Illimite | Illimite | Infra client (BYOAI) | Client | Custom |

**Pourquoi cette segmentation fonctionne :**
- **Free → Pro** : le trigger naturel c'est "j'ai un deuxieme site a connecter". C'est un moment d'expansion ou le client a deja valide la valeur du produit sur son premier site. Friction minimale, upgrade evidente.
- **Pro → Team** : le trigger c'est la securite / conformite. "Je veux que mon code ne passe pas par le meme pipeline que les autres clients." C'est un besoin d'entreprise, pas de freelance.
- **Team → Enterprise** : le trigger c'est "mon code ne doit pas quitter mon infra". Banques, sante, gouvernement.

**Gate naturel : le compte GitHub**

Le site est scope au compte GitHub de celui qui le cree. Un dev ne va pas creer 2 comptes GitHub. Donc la limite "1 site en Free" est naturellement enforced par l'identite GitHub.

Cas particulier : un dev/agence qui cree le site avec le compte GitHub de son client. C'est en fait positif — ca veut dire que le client adopte le produit directement. Le dev qui veut gerer plusieurs clients depuis son propre compte upgrade naturellement en Pro.

**Ce qui est gate techniquement :**
- La limite de sites est deja en place cote code (`existing.length >= 20` dans `POST /api/owner/sites`). Il suffit de la rendre configurable par tier au lieu d'un max fixe.
- La limite d'edits/mois se compte par `site_key` sur les appels `POST /api/edit`.
- La limite de contributors se compte par nombre de sessions uniques (username) par site.

**Strategie phase 1 (maintenant) : acquisition d'abord**

Ne pas implementer de metering strict pour l'instant. Garder la limite de sites (1 Free, 10 Pro) mais ne pas bloquer sur les edits ou les contributeurs. L'objectif c'est de choper des utilisateurs, pas de les freiner. Le metering et les limites strictes c'est du phase 2 une fois qu'on a du volume et qu'on doit controler les couts API Anthropic.

---

## Refactoring necessaire dans le code

Pour supporter ces 3 niveaux, le `EditAgent` actuel doit evoluer :

### Etape 1 : Extraire l'interface

Aujourd'hui `EditAgent` fait tout : recherche de fichiers, appel Claude, creation de PR. Il faudrait separer :

```
EditAgent (orchestrateur)
  ├── FileResolver    → trouve les fichiers candidats (GitHub API)
  ├── SourceMapper    → appelle le LLM pour mapper texte → source (c'est l'IA)
  └── PullRequestBuilder → cree la branche + PR (GitHub API)
```

Seul `SourceMapper` a besoin d'etre isole/containerise. `FileResolver` et `PullRequestBuilder` restent cote platform (ils utilisent le token GitHub du contributeur, pas de secret client).

### Etape 2 : SourceMapper comme service

Le `SourceMapper` devient un service HTTP avec le contrat decrit plus haut. 3 implementations :

1. **SourceMapper::Local** — appelle Claude directement (mode actuel, pour Free/Pro)
2. **SourceMapper::Dedicated** — appelle un container dedie (pour Team)
3. **SourceMapper::Remote** — appelle l'endpoint du client (pour Enterprise)

### Etape 3 : Configuration par site

Le `SiteStore` stockerait la config d'isolation par site :

```json
{
  "key": "sk_xxx",
  "repo": "client/website",
  "isolation": {
    "mode": "shared" | "dedicated" | "remote",
    "api_key": "sk-ant-xxx (pour dedicated, optionnel)",
    "endpoint": "https://client.internal/agent/analyze (pour remote)",
    "auth_header": "Bearer xxx (pour remote)"
  }
}
```

---

## Securite additionnelle a considerer

- **Chiffrement en transit** : les fichiers envoyes au SourceMapper doivent etre sur HTTPS/mTLS
- **Chiffrement au repos** : les fichiers lus depuis GitHub sont en memoire seulement, jamais ecrits sur disque
- **Logs** : les contenus des fichiers ne doivent JAMAIS apparaitre dans les logs (ni cote UltimateCMS, ni cote Anthropic en mode Enterprise)
- **Network policies** : en mode dedie, le container ne doit pouvoir atteindre que l'API Anthropic et rien d'autre (pas d'acces a la DB UltimateCMS, pas d'acces aux autres containers)
- **Audit trail** : logger quel agent a ete utilise pour quelle requete, sans logger le contenu
- **Rotation des cles** : si un client BYOK change sa cle API, l'ancien agent ne doit plus fonctionner

---

## Questions ouvertes

1. **Latence** : un container dedie cold-start en ~2-5s sur Cloud Run. Acceptable ? Ou faut-il garder les containers warm ?
2. **Cout** : un container dedie par client Team = cout fixe meme sans utilisation. Serverless (Lambda/Cloud Run) serait plus adapte ?
3. **Multi-modele** : si un client Enterprise utilise GPT-4 au lieu de Claude, comment on garantit la qualite des edits ? Faut-il un test suite / benchmark ?
4. **Caching** : peut-on cacher l'arbre des fichiers du repo pour eviter de re-fetcher a chaque edit ? Si oui, ou (pas dans le container partage) ?
5. **Fine-tuning** : un client Enterprise pourrait-il fine-tuner un modele sur son propre codebase pour de meilleurs resultats ? On le supporterait comment ?

---

## Prochaines etapes (si on decide d'implementer)

1. [ ] Definir le contrat API du SourceMapper (OpenAPI spec)
2. [ ] Refactorer EditAgent pour extraire SourceMapper
3. [ ] Implementer SourceMapper::Local (identique au comportement actuel)
4. [ ] Dockeriser le SourceMapper pour le mode dedie
5. [ ] Ajouter le champ `isolation` dans SiteStore
6. [ ] Ajouter le routing dans l'orchestrateur (site.isolation.mode → implementation)
7. [ ] Documenter le protocole pour les clients Enterprise (BYOAI)
8. [ ] Creer un template/SDK d'agent client (repo open-source ?)
