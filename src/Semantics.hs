module Semantics where

import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.List as List

 -------------------------------------------------------------------------------------------------
 --                                                                                             --
 -- Prototype implementation of a small DSL for commit/redeem based contracts on blockchain     --
 --                                                                                             --
 -- Structured thus:                                                                            --
 --     - basic data types                                                                      --
 --     - type of Actions (to be performed on the blockchain as a result of contract evaluation --
 --     - type of Observables (quantities which can be observed and recorded on blockchain)     --
 --     - types of Commitments (of values and of cash)                                          --
 --     - type of State (of the internal state of a DSL contract evaluation)                    --
 --     - type of Observations (of values of Observables)                                       --
 --     - type of Contracts                                                                     --
 --     - single step evaluation (the step function) which is wrapped by fullStep …             --
 --     - … which expires and refunds cash commitments                                          --
 --                                                                                             --
 -- Further discussion in accompanying document.                                                --
 -------------------------------------------------------------------------------------------------

{----------------------
 -- Basic data types --
 ----------------------} 

 -- People are represented by their public keys,
 -- which in turn are given by integers.

type Key         = Int   -- Public key
type Person      = Key

-- Block numbers and random numbers are both integers.
 
type Random      = Int
type BlockNumber = Int

-- Observables are things which are recorded on the blockchain.
--  e.g. "a random choice", the value of GBP/BTC exchange rate, …

-- Question: how do we implement these things?
--  - We assume that some mechanism exists which will ensure that the value is looked up and recorded, or …
--  - … we actually provide that mechanism explicitly, e.g. with inter-contract comms or transaction generation or something.

-- Other observables are possible, e.g. the value of the oil price at this time.
-- It is assumed that these would be provided in some agreed way by an oracle of some sort.

-- The Observable data type represents the different sorts of observables, …

data Observable = Random | BlockNumber
                    deriving (Eq,Ord,Show,Read)

-- … while the type OS gives a particular random value and block number. 
-- Can think of these as the values available at a particular step.

data OS =  OS { random       :: Random,
                blockNumber  :: BlockNumber }
                    deriving (Eq,Ord,Show,Read)

-- Inputs
-- Types for cash commits, money redeems, and choices.
--
-- A cash commitment is an integer (should be positive integer?)
-- Concrete values are sometimes chosen too: these are integers for the sake of this model.

type Cash     = Int
type ConcreteChoice = Int

-- We need to put timeouts on various operations. These could be some abstract time
-- domain, but it only really makes sense for these to be block numbers.

type Timeout = BlockNumber

-- Commitments, choices and payments are all identified by identifiers.
-- Their types are given here. In a more sophisticated model these would
-- be generated automatically (and so uniquely); here we simply assume that 
-- they are unique.

newtype IdentCC = IdentCC Int
               deriving (Eq,Ord,Show,Read)

newtype IdentChoice = IdentChoice Int
               deriving (Eq,Ord,Show,Read)

newtype IdentPay = IdentPay Int
               deriving (Eq,Ord,Show,Read)

-- A cash commitment is made by a person, for a particular amount and timeout.               

data CC = CC IdentCC Person Cash Timeout
               deriving (Eq,Ord,Show,Read)

-- A cash redemption is made by a person, for a particular amount.
               
data RC = RC IdentCC Person Cash
               deriving (Eq,Ord,Show,Read)

-- The input to a step has four components
--      - a set of cash commitments made at that step
--      - a set of cash redemptions made at that step
--      - a map of payment requests made at that step
--      - a map of choices made at that step
--
-- In practice, we could use sets for all of them,
-- but using a map ensures that there is only one
-- entry per identifier and person pair and would
-- make access more efficient if we needed to find
-- an entry without knowing the concrete choice
-- or ammount of cash being claimed.

-- If we want to be able to accept commitments that are
-- more generous than established we would need to make
-- cc a map too.

data Input = Input {
                cc  :: Set.Set CC,
                rc  :: Set.Set RC,
                rp  :: Map.Map (IdentPay, Person) Cash,
                ic  :: Map.Map (IdentChoice, Person) ConcreteChoice
              }
               deriving (Eq,Ord,Show,Read)

-- Actions are things that have an effect on the blockchain, and a set
-- of actions is generated at each step. We are not responsible for
-- making these happen: this is passed to the blockchain.
--
-- There are some actions that would not have an effect on
-- the blockchain but serve the purpouse of logging what happened
-- and to help analysis of contracts. For example, FailedPay
-- does not have an effect, but we may want to ensure that
-- it cannot be produced under any circumstance by a contract,
-- since that would imply that the contract cannot be enforced.

-- The actions represented here should be self-explanatory,
-- with the possible exception of DuplicateRedeem, which
-- just registers that two redeems have been made for
-- the same IdentCC.

data Action =   SuccessfulPay IdentPay Person Person Cash |
                ExpiredPay IdentPay Person Person Cash |
                FailedPay IdentPay Person Person Cash |
                SuccessfulCommit IdentCC Person Cash |
                CommitRedeemed IdentCC Person Cash |
                ExpiredCommitRedeemed IdentCC Person Cash |
                DuplicateRedeem IdentCC Person |
                ChoiceMade IdentChoice Person ConcreteChoice
                    deriving (Eq,Ord,Show,Read)

type AS = [Action]


-- A type of states; this represents part of the state that needs to be
-- stored on the blockchain.
--
-- Observations of observables also need to be stored on the blockchain,
-- so that computations can be re-run. Recording these should be seen as
-- a side-effect of their evaluation.

-- In particular the state keeps track of the current state of existing 
-- conmmitments (sc) and choices (sch) that have been made.

data State = State {
               sc  :: Map.Map IdentCC CCStatus,
               sch :: Map.Map (IdentChoice, Person) ConcreteChoice
             }
               deriving (Eq,Ord,Show,Read)

type CCStatus = (Person,CCRedeemStatus)
data CCRedeemStatus = NotRedeemed Cash Timeout | ManuallyRedeemed
               deriving (Eq,Ord,Show,Read)

-- Money is a set of contract primitives that represent constants,
-- functions, and variables that can be evaluated as an ammount
-- of money.

data Money = AvailableMoney IdentCC |
             AddMoney Money Money |
             ConstMoney Cash
                    deriving (Eq,Ord,Show,Read)

-- Semantics of money

-- Function that evaluates a Money construct given
-- the current state. 

evalMoney :: State -> Money -> Cash
evalMoney (State {sc = scv}) (AvailableMoney ident) =
  case Map.lookup ident scv of
    Just (_, NotRedeemed c _) -> c
    _ -> 0
evalMoney s (AddMoney a b) = (evalMoney s a) + (evalMoney s b)
evalMoney _ (ConstMoney c) = c


-- Representation of observations over observables and the state.
-- Rendered into predicates by interpretObs.

-- TO DO: add enough operations to make complete for arithmetic etc.
-- as well as enough primitive observations over the primitive values.

data Observation =  BelowTimeout Timeout | -- are we still on time for something that expires on Timeout?
                    AndObs Observation Observation |
                    OrObs Observation Observation |
                    NotObs Observation |
                    PersonChoseThis IdentChoice Person ConcreteChoice |
                    PersonChoseSomething IdentChoice Person |
                    ValueGE Money Money | -- is first ammount is greater or equal than the second?
                    TrueObs | FalseObs
                    deriving (Eq,Ord,Show,Read)

-- Semantics of observations

interpretObs :: State -> Observation -> OS -> Bool

interpretObs _ (BelowTimeout n) os
    = not $ expired (blockNumber os) n
interpretObs st (AndObs obs1 obs2) os
    = interpretObs st obs1 os && interpretObs st obs2 os
interpretObs st (OrObs obs1 obs2) os
    = interpretObs st obs1 os || interpretObs st obs2 os
interpretObs st (NotObs obs) os
    = not (interpretObs st obs os)
interpretObs st (PersonChoseThis choice_id person reference_choice) _
    = case Map.lookup (choice_id, person) (sch st) of
        Just actual_choice -> actual_choice == reference_choice
        Nothing -> False
interpretObs st (PersonChoseSomething choice_id person) _
    = Map.member (choice_id, person) (sch st)
interpretObs st (ValueGE a b) _
    = (evalMoney st a) >= (evalMoney st b)
interpretObs _ TrueObs _
    = True
interpretObs _ FalseObs _
    = False

-- The type of contracts

data Contract =
    Null |
    CommitCash IdentCC Person Cash Timeout Timeout Contract Contract |
    RedeemCC IdentCC Contract |
    Pay IdentPay Person Person Cash Timeout Contract |
    Both Contract Contract |
    Choice Observation Contract Contract |
    When Observation Timeout Contract Contract
               deriving (Eq,Ord,Show,Read)


{-------------
 - Semantics -
 -------------}

-- A single computation step in evaluating a contract.

step :: Input -> State -> Contract -> OS -> (State,Contract,AS)

step _ st Null _ = (st, Null, [])

step inp st c@(Pay idpay from to val expi con) os
    | expired (blockNumber os) expi =
         (st,con,[ExpiredPay idpay from to val])
    | right_claim =
        (if committed st from bn >= val
         then (newstate,con,[SuccessfulPay idpay from to val])
         else (st,con,[FailedPay idpay from to val]))
    | otherwise = (st,c,[])
    where
        newstate = stateUpdate st from to bn val
        bn = blockNumber os
        right_claim = case Map.lookup (idpay, to) (rp inp) of
                         Just claimed_val -> claimed_val == val
                         Nothing -> False


-- CHECK: the clause for Both could use a commitment twice,
-- but only if the identity is duplicated, and should not be possible.

step comms st (Both con1 con2) os =
    (st2, result, ac1 ++ ac2)
    where
        result | res1 == Null = res2
               | res2 == Null = res1
               | otherwise = Both res1 res2
        (st1,res1,ac1) = step comms st con1 os
        (st2,res2,ac2) = step comms st1 con2 os

step _ st (Choice obs conT conF) os =
    if interpretObs st obs os
        then (st,conT,[])
        else (st,conF,[])

step _ st (When obs expi con con2) os
  | expired (blockNumber os) expi = (st,con2,[])
  | interpretObs st obs os = (st,con,[])
  | otherwise = (st, When obs expi con con2, [])

-- Note that conformance of the commitment here is exact
-- May want to relax this

step commits st c@(CommitCash ident person val start_timeout end_timeout con1 con2) os
  | cexe || cexs = (st {sc = ust}, con2, [])
  | Set.member (CC ident person val end_timeout) (cc commits)
        = (st {sc = ust}, con1, [SuccessfulCommit ident person val])
  | otherwise = (st, c, [])
  where ccs = sc st
        cexs = expired (blockNumber os) start_timeout
        cexe = expired (blockNumber os) end_timeout
        cns = (person, if cexe || cexs then ManuallyRedeemed else NotRedeemed val end_timeout)
        ust = Map.insert ident cns ccs

-- Note: there is no possibility of payment failure here
-- Also: look at partial redemption: currently it is all or nothing.

step commits st c@(RedeemCC ident con) _ =
    case Map.lookup ident ccs of
      Just (person, NotRedeemed val _) ->
        let newstate = st {sc = Map.insert ident (person, ManuallyRedeemed) ccs} in
        if Set.member (RC ident person val) (rc commits)
        then (newstate, con, [CommitRedeemed ident person val])
        else (st, c, [])
      Just (person, ManuallyRedeemed) ->
        (st, con, [DuplicateRedeem ident person])
      Nothing -> (st,c,[])
    where
        ccs = sc st

---------------------------
-- fullStep & computeAll --
---------------------------

-- Given a choice, if no previous choice for its id has been recorded,
-- it records it in the map, and adds an action ChoiceMade to the list.

addNewChoices :: (Map.Map (IdentChoice, Person) ConcreteChoice, [Action])
                -> (IdentChoice, Person) -> ConcreteChoice
                -> (Map.Map (IdentChoice, Person) ConcreteChoice, [Action])

addNewChoices acc@(recorded_choices, action_list) (choice_id, person) choice_int
  | Map.member (choice_id, person) recorded_choices = acc
  | otherwise = (Map.insert (choice_id, person) choice_int recorded_choices,
                 ChoiceMade choice_id person choice_int : action_list)

-- It records all the choices in the input that have not been recorded before

recordChoices :: Input -> Map.Map (IdentChoice, Person) Int -> (Map.Map (IdentChoice, Person) Int, [Action])

recordChoices input recorded_choices = Map.foldlWithKey addNewChoices (recorded_choices, []) (ic input)

-- Checks whether the provided cash commit is claimed in the input
isClaimed :: Input -> IdentCC -> CCStatus -> Bool

isClaimed inp ident status
  = case status of
      (p, NotRedeemed val _) -> Set.member (RC ident p val) (rc inp)
      _ -> False

-- Checks whether the provided cash commit is expired, not redeemed, and claimed.
-- (That is, whether the conditions apply for marking it as redeemed even without RedeemCC.)

expiredAndClaimed :: Input -> Timeout -> IdentCC -> CCStatus -> Bool

expiredAndClaimed inp et k v = isExpiredNotRedeemed et v && isClaimed inp k v


-- Marks a cash commit as redeemed,
-- Idempotent: if it is already redeemed it does nothing 

markRedeemed :: CCStatus -> CCStatus

markRedeemed (p, NotRedeemed _ _) = (p, ManuallyRedeemed)
markRedeemed (p, x) = (p, x)


-- Looks for expired and claimed commits in the list of commits of the state (scf)

expireCommits :: Input -> Map.Map IdentCC CCStatus -> OS -> (Map.Map IdentCC CCStatus, [Action])

expireCommits inp scf os = (Map.union uexp nsc, pas)
  where (expi, nsc) = Map.partitionWithKey (expiredAndClaimed inp et) scf
        pas = [ExpiredCommitRedeemed ident p val | (ident, (p, NotRedeemed val _)) <- Map.toList expi]
        et = blockNumber os
        uexp = Map.map markRedeemed expi

-- Wraps step function to refund expired cash commitments

fullStep :: Input -> State -> Contract -> OS -> (State, Contract, AS)

fullStep inp st con os = (rs, rcon, nas)
  where (nsch, chas) = recordChoices inp (sch st)
        (nsc, pas) = expireCommits inp (sc st) os
        nst = st { sc = nsc, sch = nsch }
        nas = chas ++ pas ++ ras
        (rs, rcon, ras) = step inp nst con os

-- Repeatedly calls the step function (fullStep function actually) until
-- it does not change anything or produces any actions

compute_all :: Input -> State -> Contract -> OS -> (State, Contract, AS)

compute_all com st con os = compute_all_aux com st con os []

compute_all_aux :: Input -> State -> Contract -> OS -> AS -> (State, Contract, AS)

compute_all_aux com st con os ac
  | (nst == st) && (ncon == con) && (nac == []) = (st, con, ac)
  | otherwise = compute_all_aux com nst ncon os (nac ++ ac)
  where (nst, ncon, nac) = fullStep com st con os

-------------------------
-- Auxiliary functions --
-------------------------

-- How much money is committed by a person, and is still unexpired?

committed :: State -> Person -> Timeout -> Cash

committed st per current_block = sum [ v | c@(_, NotRedeemed v _) <- Map.elems ccl, isRedeemable per current_block c ]
  where ccl = sc st

-- Assume this is only called when there is enough cash available.

stateUpdate :: State -> Person -> Person -> Timeout -> Cash -> State

stateUpdate st from _ bn val = st { sc = newccs}
    where
        ccs = sc st
        newccs = updateMap ccs from bn val

-- Take Cash amount from Person commitments unexpired at time Timeout, giving
-- priority to those that expire earliest.

updateMap :: Map.Map IdentCC CCStatus -> Person -> Timeout -> Cash -> Map.Map IdentCC CCStatus
updateMap mx p e v = discountFromValid (isRedeemable p e) v mx

-- Does this particular map-record for a commitment belong to the person,
-- and is it unexpired?

isRedeemable :: Person -> Timeout -> CCStatus -> Bool
isRedeemable p e (ep, NotRedeemed _ ee) = (ep == p) && not (expired e ee)
isRedeemable _ _ _  = False 

-- Is this particular map-record for a commitment not-redeemed but expired?
isExpiredNotRedeemed :: Timeout -> CCStatus -> Bool
isExpiredNotRedeemed e (_, NotRedeemed _ ee) = expired e ee
isExpiredNotRedeemed _ (_, _) = False 

-- Defines if expiry time ee has come if current time is e
expired :: Timeout -> Timeout -> Bool
expired e ee = ee <= e

-- Removes the total Cash from those entries in the map that
-- meet the filter function, passed as first argument.

discountFromValid :: (CCStatus -> Bool) -> Cash -> Map.Map IdentCC CCStatus -> Map.Map IdentCC CCStatus
discountFromValid f v m = updated_map
  where redeemable_submap = Map.filter f m
        ordered_redeemable_list = sortByExpirationDate (Map.toList redeemable_submap)
        changes_to_map = discountFromPairList v ordered_redeemable_list
        updated_map = Map.union (Map.fromList changes_to_map) m

-- Discounts the Cash from an initial segment of the list of pairs.

discountFromPairList :: Cash -> [(IdentCC, CCStatus)] -> [(IdentCC, CCStatus)]
discountFromPairList v ((ident, (p, NotRedeemed ve e)):t)
  | v <= ve = [(ident, (p, NotRedeemed (ve - v) e))]
  | ve < v = (ident, (p, NotRedeemed 0 e)) : discountFromPairList (v - ve) t
discountFromPairList _ (_:t) = t 
discountFromPairList _ _ = error "attempt to discount when insufficient cash available"

-- Sorts a list of pairs by expiration date.

sortByExpirationDate :: [(IdentCC, CCStatus)] -> [(IdentCC, CCStatus)]
sortByExpirationDate = List.sortBy lowerExpirationDateButNotExpired

-- Compares two cash commitments regarding their expiration date,
-- it considers a commitment smaller the closer it is to its
-- expiration but without having expired.
lowerExpirationDateButNotExpired :: (IdentCC, CCStatus) -> (IdentCC, CCStatus) -> Ordering

lowerExpirationDateButNotExpired (_, (_, NotRedeemed _ e)) (_, (_, NotRedeemed _ e2)) = compare e e2
lowerExpirationDateButNotExpired (_, (_, NotRedeemed _ _)) _ = LT
lowerExpirationDateButNotExpired _ (_, (_, NotRedeemed _ _)) = GT
lowerExpirationDateButNotExpired _ _ = EQ

{----------
 - Driver -
 ----------}

-- Driver for a single step of execution, using the fullStep function
-- This first performs any repayments due because of an expired commit,
-- then calls the step function.

-- Given a start state, a contract and a stream of commits and observables,
-- produces a list of actions to perform at each step.

driver :: State -> Contract -> [(Input,OS)] -> [AS]

driver start_state contract input =
 case input of
  [] -> error "Input should be infinite in driver"
  (com1,os1):rest_input ->
    let (next_st,next_con,aset) = fullStep com1 start_state contract os1 in
    let rest                    = driver next_st next_con rest_input in aset:rest


--

inputStream :: Input -> [(Input,OS)]

inputStream commits = result
  where
    result = zip commits_stream os_stream
    commits_stream = repeat commits
    os_stream = map (OS 42) (concatMap (replicate 100) [1 ..])

