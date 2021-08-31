const EroToken = artifacts.require("EroToken");

/*
 * uncomment accounts to access the test accounts made available by the
 * Ethereum client
 * See docs: https://www.trufflesuite.com/docs/truffle/testing/writing-tests-in-javascript
 */
contract("EroToken", function (/* accounts */) {
  it("should assert true", async function () {
    await EroToken.deployed();
    return assert.isTrue(true);
  });
});
