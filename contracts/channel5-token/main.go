package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&TokenDistributionContract{})
	if err != nil {
		log.Panicf("channel5-token: failed to create chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("channel5-token: failed to start chaincode: %v", err)
	}
}
