import { calculateOptimalPayoffPlan, startDebtSettlementWatcher } from "@credit-orchestrator/debt-optimizer";

// Inside app.listen():
app.listen(PORT, () => {
  console.log(`Credit Repair Orchestrator API running on port ${PORT}`);
  startDebtSettlementWatcher();
});
