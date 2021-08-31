const ErgoToken = artifacts.require("ErgoToken");

const STARTING_LP = 3 // In BNB
module.exports = async function(deployer) {
  // Use deployer to state migration tasks.
  var adapter = ErgoToken.interfaceAdapter;
  const web3 = adapter.web3;

  await deployer.deploy(ErgoToken, { gas: 10000000 });
  
  // TODO: Assert funds are avail
  let instance = await ErgoToken.deployed();
  instance.SetupCreateLP(3, { value: web3.utils.toWei(`${STARTING_LP}`, 'ether')})
};
