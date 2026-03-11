# Reactive Layer Notes

This folder contains Reactive-network-specific deployment and operations context for Hook Safety-as-a-Service.

## Required Parameters
- `SERVICE_CONTRACT`: Reactive system contract (default `0x0000000000000000000000000000000000fffFfF`)
- `ORIGIN_CHAIN_ID`
- `DESTINATION_CHAIN_ID`
- `HOOK_ADDRESS`
- `EXECUTOR_ADDRESS`

## Testnet Targets
- Unichain Sepolia: `1301`
- Base Sepolia: `84532`
- Reactive Lasna: `5318007`

Callback proxy reference from local context docs:
- Unichain Sepolia callback proxy: `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`
- Base Sepolia callback proxy: `0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6`
- Lasna system/callback proxy: `0x0000000000000000000000000000000000fffFfF`

## Deployment Order
1. Deploy `HookSafetyFirewallHook` on origin chain.
2. Deploy `HookSafetyExecutor` on destination chain.
3. Authorize executor in hook (`setExecutor`).
4. Deploy `HookSafetyReactive` with origin hook + destination executor.
5. Fund reactive/executor callback costs.
