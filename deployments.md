# Deployments

Latest verified run date: **March 11, 2026**

Network targets:

- Unichain Sepolia (`chainId=1301`)
- Reactive Lasna (`chainId=5318007`)

## Contract Addresses

| Component | Network | Address | Explorer |
| --- | --- | --- | --- |
| HookSafetyFirewallHook | Unichain Sepolia | `0xfFb0f7AF7Ce0Dc1049fDc8fA25910299fd7480c0` | `https://sepolia.uniscan.xyz/address/0xfFb0f7AF7Ce0Dc1049fDc8fA25910299fd7480c0` |
| HookSafetyExecutor | Unichain Sepolia | `0x9dBF31FFDdDcb68A1b39f634Dbf94Db20EF93a1F` | `https://sepolia.uniscan.xyz/address/0x9dBF31FFDdDcb68A1b39f634Dbf94Db20EF93a1F` |
| Demo Executor | Unichain Sepolia | `0x63D36DD4a3735946Eb0544a2e3D1B593406f0fb5` | `https://sepolia.uniscan.xyz/address/0x63D36DD4a3735946Eb0544a2e3D1B593406f0fb5` |
| HookSafetyReactive | Lasna | `0x8190D9D73Df94756687bF1AEe6E43d41d261D3a6` | `https://lasna.reactscan.net/address/0x8190D9D73Df94756687bF1AEe6E43d41d261D3a6` |

## Deployment Tx IDs

| Step | Network | Tx ID | Explorer |
| --- | --- | --- | --- |
| Deploy Hook | Unichain Sepolia | `0x489f102a971ad4cbe45f3085cf06068242739fedfb19ef0331d2a64d78954c05` | `https://sepolia.uniscan.xyz/tx/0x489f102a971ad4cbe45f3085cf06068242739fedfb19ef0331d2a64d78954c05` |
| Deploy Executor | Unichain Sepolia | `0x11d709996e00c3fa4563ed01b6f9c6a9fd19720ce30972a298f6586340522a98` | `https://sepolia.uniscan.xyz/tx/0x11d709996e00c3fa4563ed01b6f9c6a9fd19720ce30972a298f6586340522a98` |
| Deploy Demo Executor | Unichain Sepolia | `0xb31a0d6bd9295d0fd3b6a35bcc083833a19af5ea8fd209e7bef478eea37c1edb` | `https://sepolia.uniscan.xyz/tx/0xb31a0d6bd9295d0fd3b6a35bcc083833a19af5ea8fd209e7bef478eea37c1edb` |
| Deploy Reactive | Lasna | `0x6a8c357997dcca537d4fcb82db312c966444b290b6e8a5bb871146db2ff36dc6` | `https://lasna.reactscan.net/tx/0x6a8c357997dcca537d4fcb82db312c966444b290b6e8a5bb871146db2ff36dc6` |
| Fund Reactive | Lasna | `0x49170d35d581c419b7acaf3b81d3d83b6bf212727a484d354be62f20ea8b8015` | `https://lasna.reactscan.net/tx/0x49170d35d581c419b7acaf3b81d3d83b6bf212727a484d354be62f20ea8b8015` |

## Strict Live Demo Tx IDs (`demo-sepolia-live-reactive`)

| Step | Network | Tx ID | Explorer |
| --- | --- | --- | --- |
| Authorize executor | Unichain Sepolia | `0xe152fdddcc02105fb74e63c0db639fd2fdaa7a0c53f6c740e4dba2d72b332203` | `https://sepolia.uniscan.xyz/tx/0xe152fdddcc02105fb74e63c0db639fd2fdaa7a0c53f6c740e4dba2d72b332203` |
| Configure pool policy | Unichain Sepolia | `0xcac52fe50c425c1c94a097e0250343c4123b248a80104bef6b0623a3add98cfa` | `https://sepolia.uniscan.xyz/tx/0xcac52fe50c425c1c94a097e0250343c4123b248a80104bef6b0623a3add98cfa` |
| Bind RVM permissive mode | Unichain Sepolia | `0x98330829fcf4cc51d77ec6a0d0c59710dd0956007628050434452c1f2c349cb8` | `https://sepolia.uniscan.xyz/tx/0x98330829fcf4cc51d77ec6a0d0c59710dd0956007628050434452c1f2c349cb8` |
| Clear mitigation state | Unichain Sepolia | `0xa17d61a97dca621bd8799cd56499de33146d28fdccf0d642126421769052c6c1` | `https://sepolia.uniscan.xyz/tx/0xa17d61a97dca621bd8799cd56499de33146d28fdccf0d642126421769052c6c1` |
| Baseline telemetry | Unichain Sepolia | `0x88ff38d5bd0d2d89d622945bf154f8a10993996e97dfffc7d43a647ac5d03f58` | `https://sepolia.uniscan.xyz/tx/0x88ff38d5bd0d2d89d622945bf154f8a10993996e97dfffc7d43a647ac5d03f58` |
| Anomaly telemetry | Unichain Sepolia | `0x110a379b1a0ab21b0313cc2a0ade080540fe2b69d05ba12ffef8eb5e04153dc7` | `https://sepolia.uniscan.xyz/tx/0x110a379b1a0ab21b0313cc2a0ade080540fe2b69d05ba12ffef8eb5e04153dc7` |
| Retry anomaly telemetry | Unichain Sepolia | `0xb9620a3fe82c89b7f46ec04c29d95fce2d0a7bb76e10e8128f4edd47c6fe5f1d` | `https://sepolia.uniscan.xyz/tx/0xb9620a3fe82c89b7f46ec04c29d95fce2d0a7bb76e10e8128f4edd47c6fe5f1d` |
| Lasna `MitigationPlanned` | Lasna | `N/A` | `N/A` |
| Unichain callback `MitigationExecuted` | Unichain Sepolia | `N/A` | `N/A` |

Assumption/TBD:

- Reactive public docs should be revalidated for Unichain Sepolia (`1301`) relay support if strict per-incident `event -> react -> callback` proof is required.

Canonical machine-readable source: `deployments/sepolia.json`.
