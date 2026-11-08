import { ethers } from "ethers";

const DEBT_ESCROW_ABI = [
  "event DebtPaydownLocked(bytes32 indexed settlementId, address indexed member, string accountId, uint256 lucrAmount, uint256 usdCents)",
  "function confirmAchSettlement(bytes32 settlementId, string calldata achTraceId) external",
  "function refundFailedPaydown(bytes32 settlementId) external"
];

export interface CreditorAchDestination {
  creditorName: string;
  routingNumber: string;
  accountNumber: string;
}

export async function dispatchCreditorAchPayment(
  settlementId: string,
  accountId: string,
  usdCents: number
): Promise<{ success: boolean; achTraceId?: string }> {
  const offRampUrl = process.env.FIAT_OFFRAMP_API_URL || "https://api.payment-bridge.example.com/v1/ach-credits";
  const offRampKey = process.env.FIAT_OFFRAMP_API_KEY || "sandbox";

  try {
    const response = await fetch(offRampUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${offRampKey}`
      },
      body: JSON.stringify({
        rail: "ACH_CREDIT",
        memo: `DEBT-PAYDOWN-${accountId}`,
        idempotencyKey: settlementId,
        amountCents: usdCents
      })
    });

    if (!response.ok) return { success: false };

    const data = (await response.json()) as { traceId: string };
    return { success: true, achTraceId: data.traceId };
  } catch {
    return { success: false };
  }
}

export function startDebtSettlementWatcher() {
  const rpcUrl = process.env.LUCR_RPC_URL;
  const contractAddress = process.env.LUCR_DEBT_SETTLEMENT_CONTRACT;
  const privateKey = process.env.LUCR_TREASURY_PRIVATE_KEY;

  if (!rpcUrl || !contractAddress || !privateKey) {
    console.warn("LUCR debt settlement env vars not configured; watcher running in dry-run mode.");
    return;
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);
  const contract = new ethers.Contract(contractAddress, DEBT_ESCROW_ABI, wallet);

  contract.on(
    "DebtPaydownLocked",
    async (settlementId: string, member: string, accountId: string, lucrAmount: bigint, usdCents: bigint) => {
      console.log(`[LUCR LOCK] ${lucrAmount.toString()} LUCR locked by ${member} for tradeline ${accountId}`);

      const payout = await dispatchCreditorAchPayment(settlementId, accountId, Number(usdCents));

      if (payout.success && payout.achTraceId) {
        const tx = await contract.confirmAchSettlement(settlementId, payout.achTraceId);
        await tx.wait();
        console.log(`[SETTLED] Settlement ${settlementId} finalized with ACH trace ${payout.achTraceId}`);
      } else {
        const refundTx = await contract.refundFailedPaydown(settlementId);
        await refundTx.wait();
        console.warn(`[REFUNDED] Off-ramp failed for ${settlementId}; LUCR returned to ${member}`);
      }
    }
  );
}
