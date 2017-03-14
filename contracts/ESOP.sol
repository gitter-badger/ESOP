pragma solidity ^0.4.0;
import "./ESOPTypes.sol";

contract ESOP is ESOPTypes, Upgradeable
{
  enum ESOPState { Open, Conversion }
  enum ReturnCodes { OK, InvalidEmployeeState, TooLate, InvalidParameters  }
  enum TerminationType { Regular, GoodWill, ForACause }

  //CONFIG
  // cliff duration in seconds
  uint public cliffDuration;
  // vesting duration in seconds
  uint public vestingDuration;
  // maximum promille that can fade out
  uint public maxFadeoutPromille;
  // exit bonus promille
  uint public exitBonusPromille;
  // per mille of unassigned options that new employee gets
  uint public newEmployeePoolPromille;
  // total options in base pool
  uint public totalOptions;

  // STATE
  // options that remain to be assigned
  uint public remainingOptions;
  // state of ESOP: open for new employees or during options conversion
  ESOPState public esopState; // automatically sets to Open (0)
  // list of employees
  EmployeesList public employees;
  // how many extra options inserted
  uint public totalExtraOptions;
  // when conversion event happened
  uint32 public conversionEventTime;
  // employee conversion deadline
  uint32 public employeeConversionDeadline;
  // option conversion proxy
  IOptionsConverter public optionsConverter;


  modifier hasEmployee(address e) {
    // will throw on unknown address
    if(!employees.hasEmployee(e))
      throw;
    _;
  }

  modifier onlyESOPOpen() {
    if (esopState != ESOPState.Open)
      throw;
    _;
  }

  modifier onlyESOPConversion() {
    if (esopState != ESOPState.Conversion)
      throw;
    _;
  }

  function removeEmployeesWithExpiredSignatures()
    onlyESOPOpen
    external
  {
    // removes employees that didn't sign and sends their options back to the pool
    // we let anyone to call that method and spend gas on it
    uint32 t = currentTime();
    Employee memory emp;
    for(uint i=0; i< employees.size(); i++) {
      address ea = employees.addresses(i);
      if (ea != 0) { // address(0) is deleted employee
        var sere = employees.getSerializedEmployee(ea);
        assembly { emp := sere }
        if (t > emp.timeToSign) {
          remainingOptions += emp.options;
          totalExtraOptions -= emp.extraOptions;
          employees.removeEmployee(ea);
        }
      }
    }

    // remove all employees that expired their signatures and distribute their options
    // when we remove employee we have to assign his options to employees that came later
    // we know who came later as they have less or equal number of options as employee being removed
    // list of addresses is ordered in sequence of being added
    /*address[] memory empaddrs;
    for(uint32 i=0; i< empaddrs.length; i++) {
      if (currentTime() > timeToSign) {}
      var (mod_vestingStart, mod_timeToSign, mod_fadeoutStarts, mod_options, mod_empGroupSize, mod_extraOptions, mod_state) = employees.getEmployee(empaddrs[i]);
      // user has less or same number of options so should be modified
      if (mod_maxOptions <= maxOptions &&
          // skip terminated users,they get nothing
          (mod_state == uint8(EmployeeState.WaitingForSignature) || mod_state == uint8(EmployeeState.Employed))) {
        // later employees participate in options coming from deleted employee with the same rate they participated
        // in options from the main pool: participation*remaining
        uint16 moreOptions = uint16(uint(mod_effPromille) * maxOptions);
        mod_maxOptions += moreOptions;
        maxOptions -= moreOptions;
        employees.setEmployee();
      }*/
  }

  function returnFadeoutToPool()
    onlyESOPOpen
    external
  {
    // computes fadeout for terminated employees and returns it to pool
    // we let anyone to call that method and spend gas on it
    uint32 t = currentTime();
    Employee memory emp;
    for(uint i=0; i< employees.size(); i++) {
      address ea = employees.addresses(i);
      if (ea != 0) { // address(0) is deleted employee
        var sere = employees.getSerializedEmployee(ea);
        assembly { emp := sere }
        // only terminated with not returned to pool
        if (emp.state == EmployeeState.Terminated && t != emp.fadeoutStarts) {
          uint returnedOptions = calcFadeout(t, emp.vestingStarted, emp.terminatedAt, emp.options)
            - calcFadeout(emp.fadeoutStarts, emp.vestingStarted, emp.terminatedAt, emp.options);
          uint returnedExtraOptions = calcFadeout(t, emp.vestingStarted, emp.terminatedAt, emp.extraOptions)
            - calcFadeout(emp.fadeoutStarts, emp.vestingStarted, emp.terminatedAt, emp.extraOptions);
          if (returnedOptions > 0 || returnedExtraOptions > 0) {
            employees.terminateEmployee(employees.addresses(i), emp.terminatedAt, t, EmployeeState.Terminated);
            remainingOptions += returnedOptions;
            totalExtraOptions -= returnedExtraOptions;
          }
        }
      }
    }
  }

  function calcNewEmployeeOptions(uint remaining, uint8 groupSize)
    internal
    constant
    returns (uint options)
  {
    for(uint i=0; i<groupSize; i++) {
      uint s = (remaining * newEmployeePoolPromille)/1000;
      options += s;
      remaining -= s;
    }
    return options/groupSize;
  }

  function addNewEmployeeToESOP(address e, uint32 vestingStarts, uint32 timeToSign, uint32 extraOptions)
    external
    onlyESOPOpen
    onlyOwner
    returns (ReturnCodes)
  {
    // do not add twice
    if(employees.hasEmployee(e))
      return ReturnCodes.InvalidEmployeeState;
    // recover options for employees with expired signatures
    this.removeEmployeesWithExpiredSignatures();
    // return fade out to pool
    this.returnFadeoutToPool();
    // assign options for group of size 1 obviously
    uint options = calcNewEmployeeOptions(remainingOptions, 1);
    if (options > 0xFFFF)
      throw;
    employees.setEmployee(e, vestingStarts, timeToSign, 0, 0, uint32(options), extraOptions, EmployeeState.WaitingForSignature );
    remainingOptions -= options;
    totalExtraOptions += extraOptions;
    return ReturnCodes.OK;
  }

  function addNewEmployeesToESOP(address[] emps, uint32 vestingStarts, uint32 timeToSign)
    external
    onlyESOPOpen
    onlyOwner
    returns (ReturnCodes)
  {
    // recover options for employees with expired signatures
    this.removeEmployeesWithExpiredSignatures();
    // return fade out to pool
    this.returnFadeoutToPool();
    // do not add twice
    for(uint i=0; i < emps.length; i++)
      if(employees.hasEmployee(emps[i]))
        return ReturnCodes.InvalidEmployeeState;
    // assign options for group of size 1 obviously
    uint options = calcNewEmployeeOptions(remainingOptions, uint8(emps.length));
    if (options > 0xFFFF)
      throw;
    for(i=0; i < emps.length; i++) {
      employees.setEmployee(emps[i], vestingStarts, timeToSign, 0, 0, uint32(options), 0, EmployeeState.WaitingForSignature );
      remainingOptions -= options;
    }
    return ReturnCodes.OK;
  }

  function addEmployeeWithExtraOptions(address e, uint32 vestingStarts, uint32 timeToSign, uint32 extraOptions)
    external
    onlyESOPOpen
    onlyOwner
    returns (ReturnCodes)
  {
    // do not add twice
    if(employees.hasEmployee(e))
      return ReturnCodes.InvalidEmployeeState;
    employees.setEmployee(e, vestingStarts, timeToSign, 0, 0, 0, extraOptions, EmployeeState.WaitingForSignature );
    totalExtraOptions += extraOptions;
    return ReturnCodes.OK;
  }

  function employeeSignsToESOP()
    external
    hasEmployee(msg.sender)
    onlyESOPOpen
    returns (ReturnCodes)
  {
    var sere = employees.getSerializedEmployee(msg.sender);
    Employee memory emp;
    assembly { emp := sere }
    if (emp.state != EmployeeState.WaitingForSignature)
      return ReturnCodes.InvalidEmployeeState;
    uint32 t = currentTime();
    if (t > emp.timeToSign) {
      remainingOptions += emp.options;
      totalExtraOptions -= emp.extraOptions;
      employees.removeEmployee(msg.sender);
      return ReturnCodes.TooLate;
    }
    employees.changeState(msg.sender, EmployeeState.Employed);
    return ReturnCodes.OK;
  }

  function terminateEmployee(address e, uint32 terminatedAt, uint8 terminationType)
    external
    onlyESOPOpen
    onlyOwner
    hasEmployee(e)
    returns (ReturnCodes)
  {
    // terminates an employee
    TerminationType termType = TerminationType(terminationType);
    var sere = employees.getSerializedEmployee(e);
    Employee memory emp;
    assembly { emp := sere }
    if (emp.state == EmployeeState.WaitingForSignature)
      termType = TerminationType.ForACause;
    else if (emp.state != EmployeeState.Employed)
      return ReturnCodes.InvalidEmployeeState;
    // how many options returned to pool
    uint returnedOptions = 0;
    uint returnedExtraOptions = 0;
    if (termType == TerminationType.Regular) {
      // regular termination - vesting applies
      returnedOptions = emp.options - calcVestedOptions(terminatedAt, emp.vestingStarted, emp.options);
      returnedExtraOptions = emp.extraOptions - calcVestedOptions(terminatedAt, emp.vestingStarted, emp.extraOptions);
    }
    else if (termType == TerminationType.ForACause) {
      // for a cause - employee is kicked out from ESOP, return all options
      returnedOptions = emp.options;
      returnedExtraOptions = emp.extraOptions;
    }
    // else good will - we let employee to keep all the options - already set to zero
    // terminate employee properly
    if (termType == TerminationType.ForACause)
      employees.removeEmployee(e);
    else
      employees.terminateEmployee(e, terminatedAt, terminatedAt,
        termType == TerminationType.GoodWill ? EmployeeState.GoodWillTerminated: EmployeeState.Terminated);
    remainingOptions += returnedOptions;
    totalExtraOptions -= returnedExtraOptions;
    return ReturnCodes.OK;
  }

  function increaseEmployeeOptions(address e, uint32 optionsDelta)
    external
    onlyESOPOpen
    onlyOwner
    hasEmployee(e)
    returns (ReturnCodes)
  {
    // this method is intended to increase employee options amount if other employee was terminated
    // sometimes it is not fair to give later employee more than much earlier ones
    // todo: automatically assign options returned to pool to employees
    if (optionsDelta > remainingOptions) // also checks for overflows
      return ReturnCodes.InvalidParameters;
    var sere = employees.getSerializedEmployee(e);
    Employee memory emp;
    assembly { emp := sere }
    if (emp.state != EmployeeState.Employed)
      return ReturnCodes.InvalidEmployeeState;
    emp.options += optionsDelta;
    remainingOptions -= optionsDelta;
    employees.setEmployee(e, emp.vestingStarted, emp.timeToSign, emp.terminatedAt, emp.fadeoutStarts, emp.options, emp.extraOptions, emp.state);
    return ReturnCodes.OK;
  }

  function esopConversionEvent(uint32 convertedAt, uint32 conversionDeadline , IOptionsConverter conversionProxy )
    external
    onlyESOPOpen
    onlyOwner
    returns (ReturnCodes)
  {
    // prevent stupid things, give at least two weeks for employees to convert
    if (convertedAt >= conversionDeadline || conversionDeadline + 2 weeks < currentTime())
      return ReturnCodes.TooLate;
    // convertOptions must be callable by us
    if (conversionProxy.getESOP() != address(this))
      return ReturnCodes.InvalidParameters;
    // return to pool everything we can
    this.removeEmployeesWithExpiredSignatures();
    this.returnFadeoutToPool();
    // from now vesting and fadeout stops, no new employees may be added
    conversionEventTime = convertedAt;
    employeeConversionDeadline = conversionDeadline;
    optionsConverter = conversionProxy;
    // this is very irreversible
    esopState = ESOPState.Conversion;
    return ReturnCodes.OK;
  }

  function employeeConvertsOptions()
    external
    onlyESOPConversion
    hasEmployee(msg.sender)
    returns (ReturnCodes)
  {
    uint32 ct = currentTime();
    if (ct > employeeConversionDeadline)
      return ReturnCodes.TooLate;
    Employee memory emp;
    var sere = employees.getSerializedEmployee(msg.sender);
    assembly { emp := sere }
    if (emp.state == EmployeeState.OptionsConverted)
      return ReturnCodes.InvalidEmployeeState;
    // this is ineffective as employee data will be fetched from storage again
    uint options = this.calcEffectiveOptionsForEmployee(msg.sender, ct);
    // call before options conversion contract to prevent re-entry
    employees.changeState(msg.sender, EmployeeState.OptionsConverted);
    optionsConverter.convertOptions(msg.sender, options);
    return ReturnCodes.OK;
  }

  function calcVestedOptions(uint t, uint vestingStarts, uint options)
    internal
    constant
    returns (uint)
  {
    // apply vesting
    uint effectiveTime = t - vestingStarts;
    // if within cliff nothing is due
    if (effectiveTime < cliffDuration)
      return 0;
    else
      // all option calculations are always rounded DOWN
      return  effectiveTime < vestingDuration ? (options * effectiveTime)/vestingDuration : options;
  }

  function calcFadeout(uint32 t, uint32 vestingStarted, uint32 terminatedAt, uint options)
    internal
    constant
    returns (uint)
  {
    uint32 timefromTermination = t - terminatedAt;
    uint32 fadeoutDuration = terminatedAt - vestingStarted;
    uint effectiveFadeoutPromille = timefromTermination > fadeoutDuration ? maxFadeoutPromille : maxFadeoutPromille*timefromTermination/fadeoutDuration;
    // return fadeout amount
    return options * effectiveFadeoutPromille / 1000;
  }

  function calcEffectiveOptionsForEmployee(address e, uint32 calcAtTime)
    external
    constant
    hasEmployee(e)
    returns (uint)
  {
    var sere = employees.getSerializedEmployee(e);
    Employee memory emp;
    assembly { emp := sere }
    // no more options for converted options or when esop is not singed
    if (emp.state == EmployeeState.OptionsConverted || emp.state == EmployeeState.WaitingForSignature)
      return 0;
    // no options when esop is being converted and conversion deadline expired
    if (esopState == ESOPState.Conversion && calcAtTime > employeeConversionDeadline)
      return 0;
    uint allOptions = emp.options + emp.extraOptions;
    // employee with no options
    if (allOptions == 0)
        return 0;
    // if conversion event was triggered OR employee was terminated in good will then vesting does not apply and full amount is due
    // otherwise calc vested options. for terminated employee use termination date to compute vesting, otherwise use 'now'
    uint vestedOptions = (esopState == ESOPState.Conversion || emp.state == EmployeeState.GoodWillTerminated) ?  allOptions:
      calcVestedOptions(emp.state == EmployeeState.Terminated ? emp.terminatedAt : calcAtTime, emp.vestingStarted, allOptions);
    // calc fadeout for terminated employees
    // use conversion event time to compute fadeout to stop fadeout when exit
    uint fadeoutAmount = emp.state == EmployeeState.Terminated ?
      calcFadeout(esopState == ESOPState.Conversion ? conversionEventTime : calcAtTime, emp.vestingStarted, emp.terminatedAt, vestedOptions) : 0;
    if (fadeoutAmount > vestedOptions)
      throw;
    vestedOptions -= fadeoutAmount;
    // exit bonus only on conversion event and for employees that are not terminated, no exception for good will termination
    // do not apply bonus for extraOptions
    uint bonus = (esopState == ESOPState.Conversion && emp.state == EmployeeState.Employed) ?
      (emp.options*vestedOptions*exitBonusPromille)/(1000*allOptions) : 0;
    return  vestedOptions + bonus;
  }

  function()
      payable
  {
      throw;
  }



  function ESOP() {
    // esopState = ESOPState.Open; // thats initial value
    employees = new EmployeesList();
    cliffDuration = 1 years;
    vestingDuration = 4 years;
    maxFadeoutPromille = 800;
    exitBonusPromille = 200;
    newEmployeePoolPromille = 100;
    totalOptions = 100000;
    remainingOptions = totalOptions;
  }
}